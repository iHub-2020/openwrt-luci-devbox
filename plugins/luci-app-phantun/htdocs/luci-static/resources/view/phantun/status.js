/**
 * Copyright (C) 2026 iHub-2020
 * 
 * LuCI Phantun Manager - Status Page
 * Displays real-time tunnel status, connection info, and diagnostics
 * 
 * @module luci-app-phantun/status
 * @version 1.0.0
 * @date 2026-01-31
 */

'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require rpc';
'require poll';

var lastClearTime = null;
var clearedLogCount = 0;  // Track number of logs when cleared
var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

return view.extend({
    title: _('TCP Tunnel Status'),

    pollInterval: 5,
    logPollFn: null,

    cleanText: function (str) {
        if (!str) return '';
        return String(str).replace(/\x1B\[[0-9;]*[a-zA-Z]/g, '').trim();
    },

    getLogColor: function (line) {
        var lowerLine = line.toLowerCase();
        if (lowerLine.indexOf('err') !== -1 || lowerLine.indexOf('error') !== -1 ||
            lowerLine.indexOf('fail') !== -1 || lowerLine.indexOf('panic') !== -1) {
            return '#ff6b6b'; // Red for errors
        }
        if (lowerLine.indexOf('warn') !== -1 || lowerLine.indexOf('warning') !== -1) {
            return '#ffd93d'; // Yellow for warnings
        }
        return '#ddd'; // Default color for info
    },

    getServiceStatus: function () {
        return Promise.all([
            L.resolveDefault(callServiceList('phantun'), {}),
            L.resolveDefault(fs.exec('/bin/sh', ['-c', 'pgrep -f \"phantun_server|phantun_client\"']), {})
        ]).then(function (results) {
            var serviceList = results[0];
            var psOutput = results[1];

            var instances = {};
            var isRunning = false;

            // Check service list first
            if (serviceList && serviceList.phantun && serviceList.phantun.instances) {
                for (var key in serviceList.phantun.instances) {
                    var inst = serviceList.phantun.instances[key];
                    if (inst && inst.running) {
                        isRunning = true;
                        instances[key] = {
                            pid: inst.pid,
                            command: Array.isArray(inst.command) ? inst.command.join(' ') : ''
                        };
                    }
                }
            }

            // Fallback: check if processes exist (pgrep returns 0 if found, non-zero if not found)
            if (!isRunning && psOutput && psOutput.code === 0 && psOutput.stdout && psOutput.stdout.trim()) {
                isRunning = true;
            }

            return { running: isRunning, instances: instances };
        });
    },

    getTunnelConfigs: function () {
        return uci.load('phantun').then(function () {
            var tunnels = [];
            var sections = uci.sections('phantun');

            sections.forEach(function (s) {
                if (s['.type'] === 'general') return;

                var mode = s['.type']; // 'client' or 'server'
                var localStr = '?';
                var remoteStr = '?';

                if (mode === 'server') {
                    var listenPort = s.local_port || '4567';
                    var target = s.remote_addr || '127.0.0.1';
                    var targetPort = s.remote_port || '51820';
                    localStr = '0.0.0.0:' + listenPort + ' (TCP)';
                    remoteStr = target + ':' + targetPort + ' (UDP)';
                } else {
                    var localIP = s.local_addr || '127.0.0.1';
                    var localPort = s.local_port || '51820';
                    var serverIP = s.remote_addr || '?';
                    var serverPort = s.remote_port || '?';
                    localStr = localIP + ':' + localPort + ' (UDP)';
                    remoteStr = serverIP + ':' + serverPort + ' (TCP)';
                }

                tunnels.push({
                    id: s['.name'],
                    alias: s.alias || s['.name'],
                    mode: mode,
                    disabled: s.enabled === '0',
                    local: localStr,
                    remote: remoteStr,
                    tun_local: s.tun_local || (mode === 'server' ? '192.168.201.1' : '192.168.200.1'),
                    tun_peer: s.tun_peer || (mode === 'server' ? '192.168.201.2' : '192.168.200.2')
                });
            });
            return tunnels;
        });
    },

    getRecentLogs: function () {
        var self = this;

        // Get configured log level
        return uci.load('phantun').then(function () {
            var generalSections = uci.sections('phantun', 'general');
            var logLevel = 'info';  // Default
            if (generalSections.length > 0) {
                logLevel = generalSections[0].log_level || 'info';
            }

            return fs.exec('/sbin/logread', ['-e', 'phantun']).then(function (res) {
                var output = res.stdout || '';
                if (!output && res.code !== 0) {
                    return fs.exec('/bin/sh', ['-c', 'logread | grep phantun | tail -n 150']);
                }
                return res;
            }).then(function (res) {
                var logContent = res.stdout || '';
                if (!logContent) return [];
                var lines = logContent.trim().split('\n');

                // Log level priority mapping
                var levelPriority = {
                    'trace': 0,
                    'debug': 1,
                    'info': 2,
                    'warn': 3,
                    'warning': 3,
                    'error': 4,
                    'err': 4
                };

                var selectedPriority = levelPriority[logLevel] || 2;

                // Filter by log level
                lines = lines.filter(function (line) {
                    // Extract log level (daemon.info, daemon.warn, daemon.err, etc.)
                    var match = line.match(/daemon\.(trace|debug|info|warn|warning|err|error)/i);
                    if (match) {
                        var linePriority = levelPriority[match[1].toLowerCase()] || 2;
                        return linePriority >= selectedPriority;
                    }
                    return true;  // Show lines without recognizable level
                });

                // If clear was clicked, only show logs after that time
                if (lastClearTime) {
                    lines = lines.filter(function (line) {
                        var logTime = self.parseLogTime(line);
                        if (logTime) {
                            return logTime > lastClearTime;
                        }
                        // Show marker lines
                        return line.indexOf('===') >= 0;
                    });

                    // Add highlighted clear marker at the beginning of filtered logs
                    var clearMarker = '=== Logs Cleared (' + lastClearTime.toLocaleString() + ') ===';
                    lines.unshift(clearMarker);
                }

                return lines.slice(-150).map(self.cleanText).reverse();
            });
        });
    },

    // Parse log timestamp more reliably
    parseLogTime: function (line) {
        // Format: Sat Jan 31 22:05:48 2026
        var match = line.match(/(\w{3})\s+(\w{3})\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d{4})/);
        if (!match) return null;

        var months = {
            'Jan': 0, 'Feb': 1, 'Mar': 2, 'Apr': 3, 'May': 4, 'Jun': 5,
            'Jul': 6, 'Aug': 7, 'Sep': 8, 'Oct': 9, 'Nov': 10, 'Dec': 11
        };

        var year = parseInt(match[7]);
        var month = months[match[2]];
        var day = parseInt(match[3]);
        var hour = parseInt(match[4]);
        var minute = parseInt(match[5]);
        var second = parseInt(match[6]);

        if (month === undefined) return null;

        return new Date(year, month, day, hour, minute, second);
    },

    /**
     * Calculate MD5 hash of binary files
     */
    getMD5: function () {
        return fs.exec('/bin/sh', ['-c', 'md5sum /usr/bin/phantun_client /usr/bin/phantun_server 2>/dev/null || echo "NOTFOUND"'])
            .then(function (res) {
                var output = (res.stdout || '').trim();

                if (output.indexOf('NOTFOUND') === 0) {
                    throw new Error('Binary not found');
                }

                var lines = output.split('\n');
                var md5s = {};
                lines.forEach(function (line) {
                    var match = line.match(/^([a-f0-9]{32})\s+.*\/(phantun_\w+)$/i);
                    if (match && match[1] && match[2]) {
                        md5s[match[2]] = match[1].substring(0, 16) + '...';
                    }
                });

                return md5s;
            })
            .catch(function (err) {
                return { error: err.message || 'Unknown error' };
            });
    },

    /**
     * Check iptables rules
     */
    checkIptablesRules: function () {
        return Promise.all([
            L.resolveDefault(fs.exec('/usr/sbin/iptables-save'), {}),
            L.resolveDefault(fs.exec('/usr/sbin/ip6tables-save'), {})
        ]).then(function (results) {
            var ipv4Output = (results[0] && results[0].stdout) || '';
            var ipv6Output = (results[1] && results[1].stdout) || '';

            var statusText = _('No rules detected');
            var statusColor = '#f0ad4e';
            var ruleTypes = [];

            // Strict check: parse output line by line
            var lines = ipv4Output.split('\n');
            var masqueradeFound = false;
            var dnatFound = false;
            var activeRules = false;

            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                // Check if line contains relevant IP range AND is a rule (contains -A or -I, or implicitly from iptables-save format which doesn't always show -A for all lines but usually does, or starts with -A)
                // iptables-save output: -A PREROUTING ...
                if ((line.indexOf('192.168.200') !== -1 || line.indexOf('192.168.201') !== -1) && line.indexOf('-j') !== -1) {
                    if (line.indexOf('MASQUERADE') !== -1) masqueradeFound = true;
                    if (line.indexOf('DNAT') !== -1) dnatFound = true;
                    activeRules = true;
                }
            }

            // Also accept if specific chain jump exists (though phantun usually uses built-in chains)
            // If explicit active rules found
            if (activeRules) {
                if (masqueradeFound) ruleTypes.push('MASQUERADE');
                if (dnatFound) ruleTypes.push('DNAT');

                statusColor = '#5cb85c';
                if (ruleTypes.length > 0) {
                    statusText = _('Active') + ' (' + ruleTypes.join(', ') + ')';
                } else {
                    statusText = _('Active (Rules Detected)');
                }
            }

            return {
                text: statusText,
                color: statusColor,
                ipv4: ipv4Output.split('\n').filter(function (l) {
                    return l.indexOf('192.168.200') !== -1 || l.indexOf('192.168.201') !== -1;
                }),
                ipv6: ipv6Output.split('\n').filter(function (l) {
                    return l.indexOf('fcc8') !== -1 || l.indexOf('fcc9') !== -1;
                })
            };
        }).catch(function (err) {
            return {
                text: _('Check failed'),
                color: '#d9534f',
                ipv4: [],
                ipv6: []
            };
        });
    },

    /**
     * Check TUN interfaces
     */
    checkTunInterfaces: function () {
        return fs.exec('/sbin/ip', ['addr', 'show']).then(function (res) {
            var output = res.stdout || '';
            var lines = output.split('\n');
            var tunInterfaces = [];
            var currentIface = null;

            lines.forEach(function (line) {
                // Match interface name line
                var ifaceMatch = line.match(/^\d+:\s+(tun\d+):/);
                if (ifaceMatch) {
                    currentIface = {
                        name: ifaceMatch[1],
                        state: line.indexOf('UP') !== -1 ? 'UP' : 'DOWN',
                        ipv4: [],
                        ipv6: []
                    };
                    tunInterfaces.push(currentIface);
                }

                // Match IPv4 address
                if (currentIface) {
                    var ipv4Match = line.match(/inet\s+([\d.]+\/\d+)/);
                    if (ipv4Match) {
                        currentIface.ipv4.push(ipv4Match[1]);
                    }

                    // Match IPv6 address
                    var ipv6Match = line.match(/inet6\s+([a-f0-9:]+\/\d+)/i);
                    if (ipv6Match) {
                        currentIface.ipv6.push(ipv6Match[1]);
                    }
                }
            });

            return tunInterfaces.length > 0 ? tunInterfaces : null;
        }).catch(function (err) {
            return null;
        });
    },

    load: function () {
        var self = this;
        return Promise.all([
            self.getServiceStatus(),
            self.getTunnelConfigs(),
            self.getRecentLogs(),
            self.getMD5(),
            self.checkIptablesRules(),
            self.checkTunInterfaces()
        ]);
    },

    // Wrapper for polling
    fetchStatusData: function () {
        return this.load();
    },

    render: function (data) {
        var self = this;
        var serviceStatus = data[0];
        var tunnels = data[1];
        var logs = data[2];
        var md5s = data[3];
        var iptablesRules = data[4];
        var tunInterfaces = data[5];

        var statusColor = serviceStatus.running ? '#5cb85c' : '#d9534f';
        var statusText = serviceStatus.running ? _('Running') : _('Stopped');
        var instanceCount = Object.keys(serviceStatus.instances).length;

        var container = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('TCP Tunnel Status')),

            // ==================== Service Status (Compact) ====================
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'style': 'display: flex; align-items: center; padding: 10px 0;' }, [
                    E('div', { 'style': 'width: 150px; font-weight: bold;' }, _('Service Status:')),
                    E('div', { 'id': 'service-status-text', 'style': 'font-weight: bold; color: ' + statusColor + ';' },
                        statusText + (instanceCount > 0 ? ' (' + instanceCount + ' instances)' : ''))
                ])
            ]),

            // ==================== Tunnel Status Table ====================
            E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
                E('h3', {}, _('Tunnel Status')),
                E('table', { 'class': 'table cbi-section-table', 'id': 'tunnel-status-table' }, [
                    E('tr', { 'class': 'tr table-titles' }, [
                        E('th', { 'class': 'th' }, _('Name')),
                        E('th', { 'class': 'th' }, _('Mode')),
                        E('th', { 'class': 'th' }, _('Status')),
                        E('th', { 'class': 'th' }, _('Local')),
                        E('th', { 'class': 'th' }, _('Remote')),
                        E('th', { 'class': 'th' }, _('TUN Address')),
                        E('th', { 'class': 'th' }, _('PID'))
                    ])
                ].concat(
                    self.renderTunnelRows(tunnels, serviceStatus)
                ))
            ]),

            // ==================== System Diagnostics (Compact) ====================
            E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
                E('h3', {}, _('System Diagnostics')),
                E('div', { 'style': 'display: grid; grid-template-columns: 150px 1fr; gap: 10px; padding: 10px 0;' }, [
                    E('div', { 'style': 'font-weight: bold;' }, _('Core Binary:')),
                    E('div', { 'id': 'diag-binary' }, md5s.error ?
                        E('span', { 'style': 'color: #d9534f;' }, '❌ ' + md5s.error) :
                        E('span', { 'style': 'color: #5cb85c;' }, '✓ Verified (' +
                            (md5s.phantun_client ? 'Client: ' + md5s.phantun_client.substring(0, 8) + '... ' : '') +
                            (md5s.phantun_server ? 'Server: ' + md5s.phantun_server.substring(0, 8) + '...' : '') + ')')
                    ),

                    E('div', { 'style': 'font-weight: bold;' }, _('TUN Interfaces:')),
                    E('div', { 'id': 'diag-tun' }, tunInterfaces && tunInterfaces.length > 0 ?
                        tunInterfaces.map(function (iface) {
                            var stateColor = iface.state === 'UP' ? '#5cb85c' : '#d9534f';
                            return E('div', {}, [
                                E('span', { 'style': 'color: ' + stateColor + '; font-weight: bold;' }, iface.name + ': ' + iface.state),
                                E('span', { 'style': 'margin-left: 10px; color: #888;' },
                                    (iface.ipv4.length > 0 ? iface.ipv4.join(', ') : '') +
                                    (iface.ipv6.length > 0 ? ' / ' + iface.ipv6.join(', ') : ''))
                            ]);
                        }) :
                        E('span', { 'style': 'color: #888;' }, _('None'))
                    ),

                    E('div', { 'style': 'font-weight: bold;' }, _('iptables Rules:')),
                    E('div', { 'id': 'diag-iptables' },
                        E('span', { 'style': 'color: ' + iptablesRules.color + ';' }, iptablesRules.text)
                    )
                ])
            ]),

            // ==================== Recent Logs ====================
            E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
                E('h3', { 'style': 'display:flex; justify-content:space-between; align-items:center;' }, [
                    _('Recent Logs'),
                    E('span', { 'id': 'log-status', 'style': 'font-size: 0.85em;' }, '')
                ]),
                E('div', {
                    'style': 'width: 100%; height: 500px; font-family: monospace; font-size: 12px; background: #1e1e1e; border: 1px solid #444; padding: 10px; border-radius: 3px; overflow-y: auto; white-space: pre;',
                    'id': 'syslog-container'
                }, logs.map(function (line) {
                    var color = self.getLogColor(line);
                    return E('div', { 'style': 'color: ' + color + ';' }, line);
                })),
                E('div', { 'style': 'margin-top: 5px; text-align: right;' }, [
                    E('button', {
                        'class': 'cbi-button cbi-button-negative',
                        'id': 'log-stop-btn',
                        'click': function () {
                            if (self.logPollFn) {
                                poll.remove(self.logPollFn);
                                self.logPollFn = null;
                                var logStatusEl = document.getElementById('log-status');
                                if (logStatusEl) {
                                    logStatusEl.textContent = '⏸ ' + _('Paused');
                                    logStatusEl.style.color = '#f0ad4e';
                                }
                            }
                        }
                    }, _('Stop Refresh')),
                    ' ',
                    E('button', {
                        'class': 'cbi-button cbi-button-positive',
                        'id': 'log-start-btn',
                        'click': function () {
                            if (!self.logPollFn) {
                                self.logPollFn = L.bind(self.pollLogs, self);
                                poll.add(self.logPollFn, self.pollInterval);
                                var logStatusEl = document.getElementById('log-status');
                                if (logStatusEl) {
                                    logStatusEl.textContent = '▶ ' + _('Auto-refreshing');
                                    logStatusEl.style.color = '#5cb85c';
                                }
                            }
                        }
                    }, _('Start Refresh')),
                    ' ',
                    E('button', {
                        'class': 'cbi-button cbi-button-reset',
                        'click': function () {
                            // Set clear time with 2 second buffer to avoid edge cases
                            lastClearTime = new Date(Date.now() - 2000);

                            // Immediately refresh display
                            self.pollLogs();

                            // Show notification
                            ui.addNotification(null,
                                E('p', _('Logs cleared. Showing only new logs.')),
                                'info', 3);
                        }
                    }, _('Clear Logs')),
                    ' ',
                    E('button', {
                        'class': 'cbi-button cbi-button-apply',
                        'click': function () {
                            var container = document.getElementById('syslog-container');
                            var logContent = container ? container.textContent : '';
                            var blob = new Blob([logContent], { type: 'text/plain' });
                            var url = URL.createObjectURL(blob);
                            var a = document.createElement('a');
                            a.href = url;
                            a.download = 'phantun_logs_' + new Date().toISOString().replace(/[:.]/g, '-') + '.txt';
                            a.click();
                            URL.revokeObjectURL(url);
                        }
                    }, _('Download Logs')),
                    ' ',
                    E('button', {
                        'class': 'cbi-button cbi-button-neutral',
                        'click': function () {
                            var textarea = document.getElementById('syslog-textarea');
                            textarea.scrollTop = 0;
                        }
                    }, _('Scroll to Top'))
                ])
            ])
        ])

        // Start log auto-refresh (delayed until DOM rendering is complete)
        requestAnimationFrame(function () {
            var logStatusEl = document.getElementById('log-status');
            if (logStatusEl) {
                // Set initial timestamp
                var now = new Date();
                var timeStr = now.toLocaleTimeString('en-US', {
                    hour: 'numeric',
                    minute: '2-digit',
                    second: '2-digit',
                    hour12: true
                });
                logStatusEl.textContent = 'Last updated: ' + timeStr;
                logStatusEl.style.color = '#888';

                // Start polling for logs
                self.logPollFn = L.bind(self.pollLogs, self);
                poll.add(self.logPollFn, self.pollInterval);
            }

            // Add status auto-refresh (not just logs)
            poll.add(L.bind(function () {
                return this.fetchStatusData().then(L.bind(function (newData) {
                    var statusContainer = document.querySelector('.cbi-map');
                    if (statusContainer) {
                        this.updateStatusView(statusContainer, newData);
                    }
                }, this));
            }, self), 5);  // Refresh status every 5 seconds
        });

        return container;
    },

    // Helper to render tunnel rows (shared between render and update)
    renderTunnelRows: function (tunnels, serviceStatus) {
        return tunnels.length > 0 ? tunnels.map(function (t) {
            var instanceKey = t.mode + '_' + t.id;  // Match init script format: client_cfg123 or server_cfg456
            var instance = serviceStatus.instances[instanceKey];
            var isActive = instance && instance.pid;
            var rowColor = t.disabled ? '#888' : (isActive ? '#5cb85c' : '#d9534f');
            var statusIcon = t.disabled ? '⏸' : (isActive ? '✓' : '✗');
            var statusLabel = t.disabled ? _('Disabled') : (isActive ? _('Running') : _('Stopped'));

            return E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td' }, t.alias),
                E('td', { 'class': 'td' }, t.mode === 'server' ? _('Server') : _('Client')),
                E('td', { 'class': 'td' }, E('span', { 'style': 'color: ' + rowColor + '; font-weight: bold;' }, statusIcon + ' ' + statusLabel)),
                E('td', { 'class': 'td' }, t.local),
                E('td', { 'class': 'td' }, t.remote),
                E('td', { 'class': 'td' }, t.tun_local + ' ↔ ' + t.tun_peer),
                E('td', { 'class': 'td' }, isActive ? String(instance.pid) : '-')
            ]);
        }) : [
            E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': '7', 'style': 'text-align: center; color: #888;' }, _('No tunnels configured'))
            ])
        ];
    },

    // Update the view without destroying selection
    updateStatusView: function (container, data) {
        var self = this;
        var serviceStatus = data[0];
        var tunnels = data[1];
        // data[2] (logs) handled by separate poller
        var md5s = data[3];
        var iptablesRules = data[4];
        var tunInterfaces = data[5];

        // 1. Update Service Status Text
        var statusColor = serviceStatus.running ? '#5cb85c' : '#d9534f';
        var statusText = serviceStatus.running ? _('Running') : _('Stopped');
        var instanceCount = Object.keys(serviceStatus.instances).length;

        var statusEl = container.querySelector('#service-status-text');
        if (statusEl) {
            statusEl.style.color = statusColor;
            statusEl.textContent = statusText + (instanceCount > 0 ? ' (' + instanceCount + ' instances)' : '');
        }

        // 2. Update Tunnel Table
        var tableEl = container.querySelector('#tunnel-status-table');
        if (tableEl) {
            // Remove old rows (except header)
            var rows = tableEl.querySelectorAll('.tr:not(.table-titles)');
            rows.forEach(function (r) { r.parentNode.removeChild(r); });

            // Render new rows
            var newRows = self.renderTunnelRows(tunnels, serviceStatus);
            newRows.forEach(function (r) { tableEl.appendChild(r); });
        }

        // 3. Update Diagnostics
        // TUN
        var tunEl = container.querySelector('#diag-tun');
        if (tunEl) {
            tunEl.innerHTML = '';
            if (tunInterfaces && tunInterfaces.length > 0) {
                tunInterfaces.forEach(function (iface) {
                    var stateColor = iface.state === 'UP' ? '#5cb85c' : '#d9534f';
                    tunEl.appendChild(E('div', {}, [
                        E('span', { 'style': 'color: ' + stateColor + '; font-weight: bold;' }, iface.name + ': ' + iface.state),
                        E('span', { 'style': 'margin-left: 10px; color: #888;' },
                            (iface.ipv4.length > 0 ? iface.ipv4.join(', ') : '') +
                            (iface.ipv6.length > 0 ? ' / ' + iface.ipv6.join(', ') : ''))
                    ]));
                });
            } else {
                tunEl.appendChild(E('span', { 'style': 'color: #888;' }, _('None')));
            }
        }

        // Iptables
        var iptEl = container.querySelector('#diag-iptables');
        if (iptEl) {
            iptEl.innerHTML = '';
            iptEl.appendChild(E('span', { 'style': 'color: ' + iptablesRules.color + ';' }, iptablesRules.text));
        }
    },

    pollLogs: function () {
        var self = this;
        return self.getRecentLogs().then(function (logs) {
            var container = document.getElementById('syslog-container');
            if (container) {
                container.innerHTML = '';
                logs.forEach(function (line) {
                    var color = self.getLogColor(line);
                    var div = document.createElement('div');
                    div.style.color = color;
                    div.textContent = line;
                    container.appendChild(div);
                });
            }

            // Update timestamp
            var logStatusEl = document.getElementById('log-status');
            if (logStatusEl) {
                var now = new Date();
                var timeStr = now.toLocaleTimeString('en-US', {
                    hour: 'numeric',
                    minute: '2-digit',
                    second: '2-digit',
                    hour12: true
                });
                logStatusEl.textContent = 'Last updated: ' + timeStr;
            }
        });
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
