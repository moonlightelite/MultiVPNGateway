#!/usr/bin/env node
/**
 * NordVPN WireGuard Config Downloader
 * 
 * Uses NordVPN's API to download WireGuard configs for specific countries
 * WITHOUT running the NordVPN daemon (no network modifications!)
 * 
 * Requirements:
 *   npm install axios
 * 
 * Usage:
 *   NODEVPN_USERNAME=your@email.com NORDVPN_PASSWORD=yourpass node download_wg.js
 * 
 * Or with OAuth token (recommended):
 *   NORDVPN_TOKEN=eyJ... node download_wg.js
 */

const axios = require('axios');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Configuration
const OUTPUT_DIR = process.env.OUTPUT_DIR || './wireguard_configs';

// Region list comes from config.yaml (single source of truth) — the same file
// the rest of the system reads. We shell out to `yq` (already a dependency) so
// there's no separate hardcoded country list to keep in sync.
function loadRegions() {
    const candidates = [
        process.env.CONFIG_FILE,
        path.join(__dirname, 'config.yaml'),
        '/etc/vpn/config.yaml'
    ].filter(Boolean);

    const cfg = candidates.find(p => { try { return fs.existsSync(p); } catch { return false; } });
    if (!cfg) {
        console.error('ERROR: cannot locate config.yaml (set CONFIG_FILE to override)');
        process.exit(1);
    }

    try {
        const query = '[.namespaces[] | select(.enabled != false) | ' +
            '{"code": .expected_country_code, "name": .country, "file": (.id + ".conf")}]';
        const json = execSync(`yq -o=json '${query}' ${JSON.stringify(cfg)}`, { encoding: 'utf8' });
        // NordVPN connect names use underscores (e.g. South_Korea); the API/display
        // wants spaces.
        return JSON.parse(json).map(c => ({ ...c, name: c.name.replace(/_/g, ' ') }));
    } catch (error) {
        console.error('ERROR: failed to read regions from', cfg, '-', error.message);
        console.error('(is `yq` installed?)');
        process.exit(1);
    }
}

const COUNTRIES = loadRegions();

// NordVPN API endpoints
const API_BASE = 'https://api.nordvpn.com';

class NordVPNDownloader {
    constructor() {
        this.token = process.env.NORDVPN_TOKEN;
        this.username = process.env.NORDVPN_USERNAME;
        this.password = process.env.NORDVPN_PASSWORD;
        this.authToken = null;
        
        if (!this.token && (!this.username || !this.password)) {
            console.error('ERROR: Provide NORDVPN_TOKEN or NORDVPN_USERNAME/NORDVPN_PASSWORD');
            process.exit(1);
        }
    }

    async authenticate() {
        console.log('[*] Authenticating with NordVPN...');
        
        if (this.token) {
            // Using OAuth token
            this.authToken = this.token;
            console.log('[+] Using OAuth token');
            return true;
        }
        
        try {
            // Username/password login
            const response = await axios.post(`${API_BASE}/oauth2/token`, {
                username: this.username,
                password: this.password,
                grant_type: 'password'
            }, {
                headers: {
                    'Content-Type': 'application/json'
                }
            });
            
            this.authToken = response.data.access_token;
            console.log('[+] Authenticated successfully');
            return true;
        } catch (error) {
            console.error('[-] Authentication failed:', error.response?.data || error.message);
            return false;
        }
    }

    async getCredentials() {
        console.log('[*] Fetching WireGuard credentials...');
        
        try {
            const response = await axios.get(`${API_BASE}/v1/users/services/credentials`, {
                headers: {
                    'Authorization': `Bearer ${this.authToken}`,
                    'Accept': 'application/json'
                }
            });
            
            const creds = response.data;
            console.log('[+] Got WireGuard credentials');
            
            return {
                privateKey: creds.unique_ip_private_key,
                publicKey: creds.unique_ip_public_key,
                uniqueIP: creds.unique_ip
            };
        } catch (error) {
            console.error('[-] Failed to get credentials:', error.response?.data || error.message);
            return null;
        }
    }

    async getCountryID(countryCode) {
        try {
            const response = await axios.get(`${API_BASE}/v1/servers/countries`);
            const country = response.data.find(c => c.code === countryCode);
            return country ? country.id : null;
        } catch (error) {
            console.error('[-] Failed to get country ID:', error.message);
            return null;
        }
    }

    async getRecommendedServer(countryID) {
        try {
            const response = await axios.get(`${API_BASE}/v1/servers/recommendations`, {
                params: {
                    limit: 1,
                    filters: {
                        country_id: countryID,
                        servers_technologies: 8, // WireGuard
                        servers_status: 'online'
                    }
                }
            });
            
            if (response.data.length > 0) {
                const server = response.data[0];
                console.log(`  → Recommended: ${server.hostname} (${server.ip_addresses.v4[0]})`);
                return server;
            }
            return null;
        } catch (error) {
            console.error('[-] Failed to get server recommendation:', error.message);
            return null;
        }
    }

    async downloadConfig(country, server, credentials) {
        console.log(`[*] Downloading config for ${country.name}...`);
        
        // Get specific server details
        try {
            const serverResponse = await axios.get(
                `${API_BASE}/v1/servers/${server.id}`,
                {
                    headers: {
                        'Authorization': `Bearer ${this.authToken}`
                    }
                }
            );
            
            const serverDetails = serverResponse.data;
            
            // Find WireGuard endpoint
            const wgEndpoint = serverDetails.ips.find(ip => 
                ip.type === 'IPv4' && ip.assignment === 'static'
            );
            
            if (!wgEndpoint) {
                console.error(`  [-] No WireGuard endpoint found for ${country.name}`);
                return null;
            }
            
            // Generate WireGuard config
            const config = this.generateWireGuardConfig(credentials, serverDetails, wgEndpoint.ip);
            
            // Save to file
            const outputPath = path.join(OUTPUT_DIR, country.file);
            fs.writeFileSync(outputPath, config);
            console.log(`  [+] Saved: ${outputPath}`);
            
            return config;
        } catch (error) {
            console.error(`  [-] Failed: ${error.message}`);
            return null;
        }
    }

    generateWireGuardConfig(credentials, server, endpointIP) {
        // Get first WireGuard server from the list
        const wgServers = server.servers.filter(s => 
            s.technologies.some(t => t.identifier === 'wireguard')
        );
        
        const wgServer = wgServers[0] || server;
        
        // Find the public key for WireGuard
        const wgPublicKey = wgServer.public_key || 
                           credentials.publicKey || 
                           'UNKNOWN';  // Fallback
        
        const endpoint = endpointIP || wgServer.ip || `${wgServer.hostname}:51820`;
        
        return `[Interface]
PrivateKey = ${credentials.privateKey || 'PLACEHOLDER_PRIVATE_KEY'}
Address = ${credentials.uniqueIP || '10.5.0.2'}/32
DNS = 103.86.96.96, 103.86.99.96

[Peer]
PublicKey = ${wgPublicKey}
AllowedIPs = 0.0.0.0/0
Endpoint = ${endpoint}:51820
PersistentKeepalive = 25
`;
    }

    async downloadAllConfigs() {
        // Create output directory
        if (!fs.existsSync(OUTPUT_DIR)) {
            fs.mkdirSync(OUTPUT_DIR, { recursive: true });
        }
        
        // Authenticate
        if (!await this.authenticate()) {
            return;
        }
        
        // Get credentials
        const credentials = await this.getCredentials();
        if (!credentials) {
            console.error('Failed to get credentials, exiting...');
            return;
        }
        
        console.log('');
        console.log(`Got unique IP: ${credentials.uniqueIP}`);
        console.log('');
        
        // Download configs for each country
        for (const country of COUNTRIES) {
            console.log(`\n=== ${country.name} (${country.code}) ===`);
            
            const countryID = await this.getCountryID(country.code);
            if (!countryID) {
                console.error(`  [-] Country ${country.code} not found`);
                continue;
            }
            
            const server = await this.getRecommendedServer(countryID);
            if (!server) {
                console.error(`  [-] No server found for ${country.name}`);
                continue;
            }
            
            const config = await this.downloadConfig(country, server, credentials);
            if (config) {
                console.log(`  [+] Success!`);
            }
            
            // Rate limiting
            await new Promise(resolve => setTimeout(resolve, 1000));
        }
        
        console.log('\n========================================');
        console.log('Download complete!');
        console.log(`Configs saved to: ${path.resolve(OUTPUT_DIR)}`);
        console.log('========================================');
    }
}

// Main
console.log('========================================');
console.log('NordVPN WireGuard Config Downloader');
console.log('API-based - No network modifications');
console.log('========================================\n');

const downloader = new NordVPNDownloader();
downloader.downloadAllConfigs().catch(console.error);
