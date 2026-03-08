/**
 * 标题: phantun/config.js
 * 作者: reyan
 * 日期: 2026-03-08
 * 版本: 1.1.0
 * 描述: LuCI Phantun 配置页，负责客户端/服务端实例管理、导入导出与服务控制。
 * 最近三次更新:
 *   - 2026-03-08: 修复 Add Client / Add Server 产生未保存 ghost instance 的问题。
 *   - 2026-03-08: 优化 Save / Reset 前对临时 section 的清理，避免脏 UCI 状态被提交。
 *   - 2026-03-08: 保留原有导入导出、服务控制与网格配置逻辑。
 */

'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require rpc';

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

var callInitAction = rpc.declare({
    object: 'luci',
    method: 'setInitAction',
    params: ['name', 'action'],
    expect: { result: false }
});

return view.extend({
    title: _('TCP Tunnel Configuration'),

    load: function () {
        return Promise.all([
            uci.load('phantun'),
            L.resolveDefault(fs.stat('/usr/bin/phantun_client'), null),
            L.resolveDefault(fs.stat('/usr/bin/phantun_server'), null),
            L.resolveDefault(callServiceList('phantun'), null)
        ]);
    },

    render: function (data) {
        var clientInstalled = data[1] !== null;
        var serverInstalled = data[2] !== null;
        var serviceStatus = data[3] || {};
        var installWarning = (!clientInstalled && !serverInstalled);

        var m, s, o;
        var transientSections = Object.create(null);

        var TRANSIENT_FLAG = '_transient';

        var removeTransientSection = function (section_id) {
            if (!transientSections[section_id])
                return;

            try {
                uci.remove('phantun', section_id);
            } catch (e) { }

            if (section_id === m.addedSection)
                delete m.addedSection;

            delete transientSections[section_id];
        };

        var confirmTransientSection = function (section_id) {
            try {
                uci.unset('phantun', section_id, TRANSIENT_FLAG);
            } catch (e) { }

            if (section_id === m.addedSection)
                delete m.addedSection;

            delete transientSections[section_id];
        };

        var cleanupTransientSections = function () {
            Object.keys(transientSections).forEach(removeTransientSection);
        };

        var pruneIncompleteSections = function () {
            uci.sections('phantun').forEach(function (section) {
                var type = section['.type'];
                var name = section['.name'];

                if ((section[TRANSIENT_FLAG] || transientSections[name]) &&
                    (type === 'client' || type === 'server')) {
                    uci.remove('phantun', name);
                    delete transientSections[name];
                    return;
                }

                if (type === 'client' && (!section.remote_addr || !section.remote_port)) {
                    if ((section.alias || '').trim() === '' || /^New Client$/i.test(section.alias || ''))
                        uci.remove('phantun', name);
                }

                if (type === 'server' && (!section.local_port || !section.remote_addr || !section.remote_port)) {
                    if ((section.alias || '').trim() === '' || /^New Server$/i.test(section.alias || ''))
                        uci.remove('phantun', name);
                }
            });
        };

        var openTransientSectionModal = function (grid, type, defaults) {
            var section_id = uci.add('phantun', type);
            var confirmed = false;

            Object.keys(defaults).forEach(function (key) {
                uci.set('phantun', section_id, key, defaults[key]);
            });
            uci.set('phantun', section_id, TRANSIENT_FLAG, '1');

            m.addedSection = section_id;

            transientSections[section_id] = true;

            var observer = new MutationObserver(function () {
                var modal = document.querySelector('.modal');

                if (!modal) {
                    observer.disconnect();
                    if (!confirmed)
                        removeTransientSection(section_id);
                    return;
                }

                var confirmBtn = modal.querySelector('.cbi-button-positive, .cbi-button-apply');
                if (confirmBtn && !confirmBtn.dataset.phantunTransientBound) {
                    confirmBtn.dataset.phantunTransientBound = '1';
                    confirmBtn.addEventListener('click', function () {
                        confirmed = true;
                        confirmTransientSection(section_id);
                    }, { once: true });
                }

                var cancelBtn = modal.querySelector('.button-row > button:first-child, .cbi-button-neutral, .cbi-button-reset');
                if (cancelBtn && !cancelBtn.dataset.phantunTransientCancelBound) {
                    cancelBtn.dataset.phantunTransientCancelBound = '1';
                    cancelBtn.addEventListener('click', function () {
                        if (!confirmed)
                            removeTransientSection(section_id);
                    }, { once: true });
                }
            });

            observer.observe(document.body, { childList: true, subtree: true });
            return grid.renderMoreOptionsModal(section_id);
        };

        m = new form.Map('phantun', _('TCP Tunnel Configuration'),
            _('TCP Tunnel (Phantun) is a lightweight UDP to TCP obfuscator. It creates TUN interfaces and requires proper iptables NAT rules. ' +
                'Configure client mode to connect to a server, or server mode to accept client connections.'));



        // ==================== Import/Export Functions ====================

        // Export server configurations
        var exportServerConfig = function () {
            var serverSections = uci.sections('phantun', 'server');
            if (serverSections.length === 0) {
                return;
            }

            var exportData = {
                type: 'server',
                version: '1.0',
                timestamp: new Date().toISOString(),
                configs: serverSections.map(function (section) {
                    var config = {};
                    for (var key in section) {
                        if (key !== '.anonymous' && key !== '.index' && key !== '.type') {
                            config[key] = section[key];
                        }
                    }
                    return config;
                })
            };

            var blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
            var url = URL.createObjectURL(blob);
            var a = document.createElement('a');
            a.href = url;
            a.download = 'phantun_servers_' + new Date().toISOString().slice(0, 19).replace(/:/g, '-') + '.json';
            a.click();
            URL.revokeObjectURL(url);
        };

        // Import server configurations
        var importServerConfig = function () {
            var input = document.createElement('input');
            input.type = 'file';
            input.accept = '.json';
            input.onchange = function (e) {
                var file = e.target.files[0];
                if (!file) return;

                var reader = new FileReader();
                reader.onload = function (e) {
                    try {
                        var data = JSON.parse(e.target.result);
                        validateAndImportServers(data);
                    } catch (err) {
                        ui.showModal(_('Import Error'), [
                            E('p', {}, _('Invalid JSON file: ') + err.message),
                            E('div', { 'class': 'right' }, [
                                E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
                            ])
                        ]);
                    }
                };
                reader.readAsText(file);
            };
            input.click();
        };

        // Validate and import server data
        var validateAndImportServers = function (data) {
            if (!data || data.type !== 'server' || !Array.isArray(data.configs)) {
                ui.showModal(_('Import Error'), [
                    E('p', {}, _('Invalid server configuration file format')),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
                    ])
                ]);
                return;
            }

            var validConfigs = [];
            var errors = [];

            data.configs.forEach(function (config, index) {
                var error = validateServerConfig(config, index + 1);
                if (error) {
                    errors.push(error);
                } else {
                    validConfigs.push(config);
                }
            });

            if (errors.length > 0) {
                ui.showModal(_('Import Validation Errors'), [
                    E('p', {}, _('The following errors were found:')),
                    E('ul', {}, errors.map(function (err) { return E('li', {}, err); })),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
                        E('button', {
                            'class': 'cbi-button cbi-button-positive',
                            'click': function () {
                                ui.hideModal();
                                if (validConfigs.length > 0) {
                                    importValidServers(validConfigs);
                                }
                            }
                        }, _('Import Valid Configs') + ' (' + validConfigs.length + ')')
                    ])
                ]);
            } else {
                importValidServers(validConfigs);
            }
        };

        // Validate individual server config
        var validateServerConfig = function (config, index) {
            if (!config.local_port || !/^\d+$/.test(config.local_port) ||
                parseInt(config.local_port) < 1 || parseInt(config.local_port) > 65535) {
                return _('Config') + ' ' + index + ': ' + _('Invalid TCP Listen Port');
            }
            if (!config.remote_addr || !/^[\w\.-]+$/.test(config.remote_addr)) {
                return _('Config') + ' ' + index + ': ' + _('Invalid Forward To IP');
            }
            if (!config.remote_port || !/^\d+$/.test(config.remote_port) ||
                parseInt(config.remote_port) < 1 || parseInt(config.remote_port) > 65535) {
                return _('Config') + ' ' + index + ': ' + _('Invalid Forward To Port');
            }
            return null;
        };

        // Import valid server configurations
        var importValidServers = function (configs) {
            var imported = 0;
            configs.forEach(function (config) {
                var section_id = uci.add('phantun', 'server');
                for (var key in config) {
                    if (key !== '.name') {
                        uci.set('phantun', section_id, key, config[key]);
                    }
                }
                // Set defaults for missing fields
                if (!config.enabled) uci.set('phantun', section_id, 'enabled', '1');
                if (!config.tun_local) uci.set('phantun', section_id, 'tun_local', '192.168.201.1');
                if (!config.tun_peer) uci.set('phantun', section_id, 'tun_peer', '192.168.201.2');
                imported++;
            });

            // Save configurations to system
            uci.save().then(function () {
                ui.showModal(_('Import Successful'), [
                    E('p', {}, _('Successfully imported ') + imported + _(' server configuration(s).')),
                    E('div', { 'class': 'right' }, [
                        E('button', {
                            'class': 'cbi-button cbi-button-positive',
                            'click': function () {
                                ui.hideModal();
                                window.location.reload();
                            }
                        }, _('OK'))
                    ])
                ]);
            });
        };

        // Export client configurations
        var exportClientConfig = function () {
            var clientSections = uci.sections('phantun', 'client');
            if (clientSections.length === 0) {
                return;
            }

            var exportData = {
                type: 'client',
                version: '1.0',
                timestamp: new Date().toISOString(),
                configs: clientSections.map(function (section) {
                    var config = {};
                    for (var key in section) {
                        if (key !== '.anonymous' && key !== '.index' && key !== '.type') {
                            config[key] = section[key];
                        }
                    }
                    return config;
                })
            };

            var blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
            var url = URL.createObjectURL(blob);
            var a = document.createElement('a');
            a.href = url;
            a.download = 'phantun_clients_' + new Date().toISOString().slice(0, 19).replace(/:/g, '-') + '.json';
            a.click();
            URL.revokeObjectURL(url);
        };

        // Import client configurations
        var importClientConfig = function () {
            var input = document.createElement('input');
            input.type = 'file';
            input.accept = '.json';
            input.onchange = function (e) {
                var file = e.target.files[0];
                if (!file) return;

                var reader = new FileReader();
                reader.onload = function (e) {
                    try {
                        var data = JSON.parse(e.target.result);
                        validateAndImportClients(data);
                    } catch (err) {
                        ui.showModal(_('Import Error'), [
                            E('p', {}, _('Invalid JSON file: ') + err.message),
                            E('div', { 'class': 'right' }, [
                                E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
                            ])
                        ]);
                    }
                };
                reader.readAsText(file);
            };
            input.click();
        };

        // Validate and import client data
        var validateAndImportClients = function (data) {
            if (!data || data.type !== 'client' || !Array.isArray(data.configs)) {
                ui.showModal(_('Import Error'), [
                    E('p', {}, _('Invalid client configuration file format')),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
                    ])
                ]);
                return;
            }

            var validConfigs = [];
            var errors = [];

            data.configs.forEach(function (config, index) {
                var error = validateClientConfig(config, index + 1);
                if (error) {
                    errors.push(error);
                } else {
                    validConfigs.push(config);
                }
            });

            if (errors.length > 0) {
                ui.showModal(_('Import Validation Errors'), [
                    E('p', {}, _('The following errors were found:')),
                    E('ul', {}, errors.map(function (err) { return E('li', {}, err); })),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
                        E('button', {
                            'class': 'cbi-button cbi-button-positive',
                            'click': function () {
                                ui.hideModal();
                                if (validConfigs.length > 0) {
                                    importValidClients(validConfigs);
                                }
                            }
                        }, _('Import Valid Configs') + ' (' + validConfigs.length + ')')
                    ])
                ]);
            } else {
                importValidClients(validConfigs);
            }
        };

        // Validate individual client config
        var validateClientConfig = function (config, index) {
            if (!config.remote_addr || !/^[\w\.-]+$/.test(config.remote_addr)) {
                return _('Config') + ' ' + index + ': ' + _('Invalid Server Address');
            }
            if (!config.remote_port || !/^\d+$/.test(config.remote_port) ||
                parseInt(config.remote_port) < 1 || parseInt(config.remote_port) > 65535) {
                return _('Config') + ' ' + index + ': ' + _('Invalid Server Port');
            }
            if (!config.local_port || !/^\d+$/.test(config.local_port) ||
                parseInt(config.local_port) < 1 || parseInt(config.local_port) > 65535) {
                return _('Config') + ' ' + index + ': ' + _('Invalid Local Port');
            }
            return null;
        };

        // Import valid client configurations
        var importValidClients = function (configs) {
            var imported = 0;
            configs.forEach(function (config) {
                var section_id = uci.add('phantun', 'client');
                for (var key in config) {
                    if (key !== '.name') {
                        uci.set('phantun', section_id, key, config[key]);
                    }
                }
                // Set defaults for missing fields
                if (!config.enabled) uci.set('phantun', section_id, 'enabled', '1');
                if (!config.local_addr) uci.set('phantun', section_id, 'local_addr', '127.0.0.1');
                if (!config.tun_local) uci.set('phantun', section_id, 'tun_local', '192.168.200.1');
                if (!config.tun_peer) uci.set('phantun', section_id, 'tun_peer', '192.168.200.2');
                imported++;
            });

            // Save configurations to system
            uci.save().then(function () {
                ui.showModal(_('Import Successful'), [
                    E('p', {}, _('Successfully imported ') + imported + _(' client configuration(s).')),
                    E('div', { 'class': 'right' }, [
                        E('button', {
                            'class': 'cbi-button cbi-button-positive',
                            'click': function () {
                                ui.hideModal();
                                window.location.reload();
                            }
                        }, _('OK'))
                    ])
                ]);
            });
        };

        // ==================== Service Status Logic ====================
        var isRunning = false;
        var runningCount = 0;

        try {
            if (serviceStatus && serviceStatus.phantun && serviceStatus.phantun.instances) {
                var instances = serviceStatus.phantun.instances;
                for (var key in instances) {
                    if (instances[key].running) {
                        isRunning = true;
                        runningCount++;
                    }
                }
            }
        } catch (e) { console.error(e); }

        var statusColor = isRunning ? '#5cb85c' : '#d9534f';
        var statusText = isRunning
            ? _('Running') + ' (' + runningCount + ' ' + _('instances active') + ')'
            : _('Stopped');

        // ==================== Info & Warning Area ====================
        m.description = E('div', {}, [
            // Status Bar
            E('div', { 'class': 'cbi-section', 'style': 'margin-bottom: 10px; padding: 10px; background: #2d3a4a; border-radius: 5px;' }, [
                E('table', { 'style': 'width: auto;' }, [
                    E('tr', {}, [
                        E('td', { 'style': 'font-weight: bold; padding-right: 10px;' }, _('Service Status:')),
                        E('td', {}, E('span', { 'style': 'color: ' + statusColor + '; font-weight: bold;' }, statusText))
                    ])
                ])
            ]),
            // Important Information
            E('div', { 'class': 'alert-message warning', 'style': 'margin-bottom: 20px; background-color: #d4a017;' }, [
                E('h4', { 'style': 'margin: 0 0 10px 0;' }, '⚠️ ' + _('Important Safety Information')),
                E('ul', { 'style': 'margin: 0; padding-left: 20px;' }, [
                    E('li', {}, _('Phantun creates TUN interfaces and uses FakeTCP to obfuscate UDP traffic.')),
                    E('li', {}, _('Client mode requires MASQUERADE iptables rules (automatically added).')),
                    E('li', {}, _('Server mode requires DNAT iptables rules (automatically added).')),
                    E('li', {}, _('No encryption - Phantun focuses on pure obfuscation for maximum performance.')),
                    E('li', {}, _('MTU overhead is only 12 bytes (TCP header - UDP header).'))
                ])
            ])
        ]);

        // ==================== General Settings ====================
        s = m.section(form.TypedSection, 'general', _('General Settings'),
            _('Global settings for the Phantun daemon.'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('Enable Service'),
            _('Master switch. If disabled, no instances will run.'));
        o.default = '1';
        o.rmempty = false;

        o = s.option(form.ListValue, 'log_level', _('Log Level'),
            _('Logging verbosity (uses RUST_LOG environment variable).'));
        o.value('error', _('Error'));
        o.value('warn', _('Warning'));
        o.value('info', _('Info (Default)'));
        o.value('debug', _('Debug'));
        o.value('trace', _('Trace (Very Verbose)'));
        o.default = 'info';

        o = s.option(form.Flag, 'keep_rule', _('Keep Firewall Rules'),
            _('Automatically restore iptables rules if they are cleared by the system (firewall reload). Recommended.'));
        o.default = '0';

        o = s.option(form.Flag, 'wait_lock', _('Wait for Iptables Lock'),
            _('Use the -w flag when invoking iptables to avoid failures during concurrent operations.'));
        o.default = '0';

        o = s.option(form.Flag, 'retry_on_error', _('Retry on Error'),
            _('Automatically restart the service if it crash or exits unexpectedly.'));
        o.default = '0';

        // ==================== Server Instances ====================
        s = m.section(form.GridSection, 'server', _('Server Instances'),
            _('<b>Server Mode:</b> OpenWrt listens for TCP connections from Phantun clients and forwards to local UDP service.<br/>' +
                'Traffic Flow: Remote Phantun Client → [TCP Obfuscated] → Phantun Server → Local UDP Service.'));
        s.anonymous = false;
        s.addremove = true;
        s.sortable = true;
        s.nodescriptions = true;
        s.addbtntitle = _('Add Server');

        s.renderSectionAdd = function (extra_class) {
            var container = E('div', { 'class': 'cbi-section-add' });

            var addBtn = E('button', {
                'class': 'cbi-button cbi-button-add',
                'title': _('Add server instance'),
                'click': ui.createHandlerFn(this, function () {
                    return openTransientSectionModal(this, 'server', {
                        enabled: '1',
                        local_port: '4567',
                        remote_addr: '127.0.0.1',
                        remote_port: '51820',
                        tun_local: '192.168.201.1',
                        tun_peer: '192.168.201.2',
                        ipv4_only: '0',
                        tun_local6: 'fcc9::1',
                        tun_peer6: 'fcc9::2'
                    });
                })
            }, _('Add Server'));

            container.appendChild(addBtn);
            container.appendChild(E('span', { 'style': 'margin: 0 5px;' }));

            var importBtn = E('button', {
                'class': 'cbi-button cbi-button-positive',
                'title': _('Import server configurations'),
                'click': function (ev) {
                    ev.preventDefault();
                    ev.stopPropagation();
                    importServerConfig();
                }
            }, _('Import Servers'));

            container.appendChild(importBtn);
            container.appendChild(E('span', { 'style': 'margin: 0 5px;' }));

            var exportBtn = E('button', {
                'class': 'cbi-button cbi-button-apply',
                'title': _('Export server configurations'),
                'click': function (ev) {
                    ev.preventDefault();
                    ev.stopPropagation();
                    exportServerConfig();
                }
            }, _('Export Servers'));

            container.appendChild(exportBtn);
            return container;
        };

        s.sectiontitle = function (section_id) {
            var alias = uci.get('phantun', section_id, 'alias');
            return alias ? (alias + ' (Server)') : _('New Server');
        };

        s.tab('basic', _('Basic Settings'));
        s.tab('advanced', _('Advanced Settings'));

        // Table Columns (Server) - 调整列宽
        o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
        o.default = '1';
        o.editable = true;
        o.rmempty = false;
        o.width = '10%';

        o = s.taboption('basic', form.Value, 'alias', _('Alias'));
        o.placeholder = 'MyServer';
        o.rmempty = true;
        o.modalonly = true;

        o = s.taboption('basic', form.Value, 'local_port', _('TCP Listen Port'));
        o.datatype = 'port';
        o.rmempty = false;
        o.width = '18%';

        o = s.taboption('basic', form.Value, 'remote_addr', _('Forward To IP'));
        o.datatype = 'host';
        o.placeholder = '10.10.10.1';
        o.rmempty = false;
        o.width = '15%';

        o = s.taboption('basic', form.Value, 'remote_port', _('Forward To Port'));
        o.datatype = 'port';
        o.rmempty = false;
        o.width = '15%';

        // Advanced Settings
        o = s.taboption('advanced', form.Flag, 'ipv4_only', _('IPv4 Only'),
            _('Only use IPv4. Disables IPv6 addresses on TUN interface.'));
        o.default = '0';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_name', _('TUN Interface Name'),
            _('Custom name for TUN interface. Leave empty for auto-assign (tun0, tun1, etc).'));
        o.placeholder = 'tun0';
        o.optional = true;
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_local', _('TUN Local IPv4'),
            _('IPv4 address for OS side of TUN interface. Default 192.168.201.1.'));
        o.datatype = 'ip4addr';
        o.default = '192.168.201.1';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_peer', _('TUN Peer IPv4'),
            _('IPv4 address for Phantun side of TUN interface. DNAT rules will redirect to this IP. Default 192.168.201.2.'));
        o.datatype = 'ip4addr';
        o.default = '192.168.201.2';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_local6', _('TUN Local IPv6'),
            _('IPv6 address for OS side of TUN interface. Default fcc9::1.'));
        o.datatype = 'ip6addr';
        o.default = 'fcc9::1';
        o.depends('ipv4_only', '0');
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_peer6', _('TUN Peer IPv6'),
            _('IPv6 address for Phantun side of TUN interface. Default fcc9::2.'));
        o.datatype = 'ip6addr';
        o.default = 'fcc9::2';
        o.depends('ipv4_only', '0');
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'handshake_packet', _('Handshake Packet File'),
            _('Path to file containing custom handshake packet to send after TCP connection. Advanced feature.'));
        o.optional = true;
        o.modalonly = true;

        // ==================== Client Instances ====================
        s = m.section(form.GridSection, 'client', _('Client Instances'),
            _('<b>Client Mode:</b> OpenWrt listens for UDP locally and connects to a remote Phantun server.<br/>' +
                'Traffic Flow: Local UDP App → Phantun Client → [TCP Obfuscated] → Remote Phantun Server → Remote UDP Service.'));
        s.anonymous = false;
        s.addremove = true;
        s.sortable = true;
        s.nodescriptions = true;
        s.addbtntitle = _('Add Client');

        s.renderSectionAdd = function (extra_class) {
            var container = E('div', { 'class': 'cbi-section-add' });

            var addBtn = E('button', {
                'class': 'cbi-button cbi-button-add',
                'title': _('Add client instance'),
                'click': ui.createHandlerFn(this, function () {
                    return openTransientSectionModal(this, 'client', {
                        enabled: '1',
                        local_addr: '127.0.0.1',
                        local_port: '51820',
                        tun_local: '192.168.200.1',
                        tun_peer: '192.168.200.2',
                        ipv4_only: '0',
                        tun_local6: 'fcc8::1',
                        tun_peer6: 'fcc8::2'
                    });
                })
            }, _('Add Client'));

            container.appendChild(addBtn);
            container.appendChild(E('span', { 'style': 'margin: 0 5px;' }));

            var importBtn = E('button', {
                'class': 'cbi-button cbi-button-positive',
                'title': _('Import client configurations'),
                'click': function (ev) {
                    ev.preventDefault();
                    ev.stopPropagation();
                    importClientConfig();
                }
            }, _('Import Clients'));

            container.appendChild(importBtn);
            container.appendChild(E('span', { 'style': 'margin: 0 5px;' }));

            var exportBtn = E('button', {
                'class': 'cbi-button cbi-button-apply',
                'title': _('Export client configurations'),
                'click': function (ev) {
                    ev.preventDefault();
                    ev.stopPropagation();
                    exportClientConfig();
                }
            }, _('Export Clients'));

            container.appendChild(exportBtn);
            return container;
        };

        s.sectiontitle = function (section_id) {
            var alias = uci.get('phantun', section_id, 'alias');
            return alias ? (alias + ' (Client)') : _('New Client');
        };

        s.tab('basic', _('Basic Settings'));
        s.tab('advanced', _('Advanced Settings'));

        // Table Columns (Client) - 调整列宽
        o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
        o.default = '1';
        o.editable = true;
        o.rmempty = false;
        o.width = '10%';

        o = s.taboption('basic', form.Value, 'alias', _('Alias'));
        o.placeholder = 'MyClient';
        o.rmempty = true;
        o.modalonly = true;

        o = s.taboption('basic', form.Value, 'local_port', _('Local Listen Port'));
        o.datatype = 'port';
        o.rmempty = false;
        o.width = '18%';

        o = s.taboption('basic', form.Value, 'remote_addr', _('Server Address'));
        o.datatype = 'host';
        o.placeholder = '10.10.10.1';
        o.rmempty = false;
        o.width = '15%';

        o = s.taboption('basic', form.Value, 'remote_port', _('Server Port'));
        o.datatype = 'port';
        o.rmempty = false;
        o.width = '15%';

        // Modal Only Options - Basic
        o = s.taboption('basic', form.Value, 'local_addr', _('Local UDP Address'),
            _('IP address to bind for incoming UDP packets. Use 127.0.0.1 for WireGuard/OpenVPN.'));
        o.datatype = 'ipaddr';
        o.default = '127.0.0.1';
        o.modalonly = true;

        // Advanced Settings
        o = s.taboption('advanced', form.Flag, 'ipv4_only', _('IPv4 Only'),
            _('Only use IPv4. Disables IPv6 addresses on TUN interface.'));
        o.default = '0';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_name', _('TUN Interface Name'),
            _('Custom name for TUN interface. Leave empty for auto-assign (tun0, tun1, etc).'));
        o.placeholder = 'tun0';
        o.optional = true;
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_local', _('TUN Local IPv4'),
            _('IPv4 address for OS side of TUN interface. Default 192.168.200.1.'));
        o.datatype = 'ip4addr';
        o.default = '192.168.200.1';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_peer', _('TUN Peer IPv4'),
            _('IPv4 address for Phantun side of TUN interface. MASQUERADE rules will be added for this IP. Default 192.168.200.2.'));
        o.datatype = 'ip4addr';
        o.default = '192.168.200.2';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_local6', _('TUN Local IPv6'),
            _('IPv6 address for OS side of TUN interface. Default fcc8::1.'));
        o.datatype = 'ip6addr';
        o.default = 'fcc8::1';
        o.depends('ipv4_only', '0');
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'tun_peer6', _('TUN Peer IPv6'),
            _('IPv6 address for Phantun side of TUN interface. Default fcc8::2.'));
        o.datatype = 'ip6addr';
        o.default = 'fcc8::2';
        o.depends('ipv4_only', '0');
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'handshake_packet', _('Handshake Packet File'),
            _('Path to file containing custom handshake packet to send after TCP connection. Advanced feature.'));
        o.optional = true;
        o.modalonly = true;

        // ==================== Override Save / Reset On View Level ====================
        this.handleSave = function () {
            cleanupTransientSections();
            pruneIncompleteSections();

            return m.save(null, true).then(function () {
                ui.addNotification(null, E('p', _('Configuration saved successfully')), 'info');
                setTimeout(function () { window.location.reload(); }, 800);
            });
        };

        this.handleSaveApply = function (ev, mode) {
            cleanupTransientSections();
            pruneIncompleteSections();

            return m.save(null, true).then(function () {
                ui.showModal(_('Applying Configuration'), [
                    E('p', { 'class': 'spinning' }, _('Saving configuration...'))
                ]);

                var general = uci.sections('phantun', 'general')[0];
                var enabled = general ? uci.get('phantun', general['.name'], 'enabled') : '0';
                var action = enabled === '1' ? 'restart' : 'stop';

                return callInitAction('phantun', action).then(function () {
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Configuration applied successfully')), 'info');
                    setTimeout(function () { window.location.reload(); }, 1500);
                }).catch(function (err) {
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Configuration saved but failed to control service: ') + (err.message || err)), 'error');
                });
            });
        };

        this.handleReset = function () {
            cleanupTransientSections();
            pruneIncompleteSections();
            uci.unload('phantun');

            return uci.load('phantun').then(function () {
                window.location.reload();
            });
        };

        // ==================== Modify Reset Button After Render ====================
        var originalRender = m.render.bind(m);
        m.render = function () {
            var mapEl = originalRender();

            // Create the reset click handler function
            var handleResetClick = function (ev) {
                ev.preventDefault();
                ev.stopPropagation();
                cleanupTransientSections();
                pruneIncompleteSections();

                ui.showModal(_('Reset Configuration'), [
                    E('p', {}, _('Are you sure you want to reset all TCP tunnel configurations?')),
                    E('p', {}, _('This will:')),
                    E('ul', {}, [
                        E('li', {}, _('Clear all server and client configurations')),
                        E('li', {}, _('Stop the phantun service')),
                        E('li', {}, _('Reset general settings to defaults'))
                    ]),
                    E('div', { 'class': 'right' }, [
                        E('button', {
                            'class': 'cbi-button cbi-button-neutral',
                            'click': ui.hideModal
                        }, _('Cancel')),
                        E('button', {
                            'class': 'cbi-button cbi-button-negative',
                            'click': function () {
                                ui.hideModal();
                                performReset();
                            }
                        }, _('Reset'))
                    ])
                ]);
            };

            // Function to perform the actual reset
            var performReset = function () {
                ui.showModal(_('Resetting Configuration'), [
                    E('p', { 'class': 'spinning' }, _('Clearing all configurations...'))
                ]);

                // Ensure we interact with the latest config state
                uci.load('phantun').then(function () {
                    return callInitAction('phantun', 'stop');
                }).then(function () {
                    // Clear all server sections
                    var serverSections = uci.sections('phantun', 'server');
                    serverSections.forEach(function (section) {
                        uci.remove('phantun', section['.name']);
                    });

                    // Clear all client sections
                    var clientSections = uci.sections('phantun', 'client');
                    clientSections.forEach(function (section) {
                        uci.remove('phantun', section['.name']);
                    });

                    // Reset general section to defaults
                    var generalSections = uci.sections('phantun', 'general');
                    if (generalSections.length > 0) {
                        var generalSection = generalSections[0]['.name'];
                        uci.set('phantun', generalSection, 'enabled', '0');
                        uci.set('phantun', generalSection, 'log_level', 'info');
                        uci.set('phantun', generalSection, 'keep_rule', '0');
                        uci.set('phantun', generalSection, 'wait_lock', '0');
                        uci.set('phantun', generalSection, 'retry_on_error', '0');
                    } else {
                        var general_id = uci.add('phantun', 'general');
                        uci.set('phantun', general_id, 'enabled', '0');
                        uci.set('phantun', general_id, 'log_level', 'info');
                        uci.set('phantun', general_id, 'keep_rule', '0');
                        uci.set('phantun', general_id, 'wait_lock', '0');
                        uci.set('phantun', general_id, 'retry_on_error', '0');
                    }

                    // Save changes
                    return uci.save();
                }).then(function () {
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Configuration reset successfully')), 'info');
                    setTimeout(function () {
                        window.location.reload();
                    }, 1500);
                }).catch(function (err) {
                    ui.hideModal();
                    ui.addNotification(null,
                        E('p', _('Failed to reset configuration: ') + (err.message || err)),
                        'error');
                });
            };

            // Function to apply button modifications
            var applyButtonMods = function () {
                var resetBtn = document.querySelector('.cbi-button-reset');

                if (resetBtn) {
                    // Force override onclick
                    resetBtn.onclick = handleResetClick;

                    // Remove color classes first
                    resetBtn.classList.remove('cbi-button-positive', 'cbi-button-negative');//, 'cbi-button-neutral');

                    // Set text and style for reset button
                    resetBtn.textContent = _('Reset');
                    // resetBtn.classList.add('cbi-button-neutral');
                    resetBtn.title = _('Reset all configurations to defaults');

                    return true;
                }
                return false;
            };

            // Apply immediately after render
            requestAnimationFrame(function () {
                var attempts = 0;
                var maxAttempts = 30;

                var tryApply = function () {
                    if (applyButtonMods()) {
                        // Success - now set up periodic check (but reduce frequency)
                        setInterval(applyButtonMods, 1000);
                    } else if (attempts < maxAttempts) {
                        attempts++;
                        requestAnimationFrame(tryApply);
                    }
                };

                tryApply();
            });

            return mapEl;
        };

        return m.render().then(function (mapEl) {
            if (!installWarning) {
                return mapEl;
            }

            return E([], [
                E('div', { 'class': 'alert-message warning' }, [
                    E('h3', {}, _('Phantun Runtime Not Installed Yet')),
                    E('p', {}, _('The configuration UI is available, but phantun_client / phantun_server are not present in the current runtime. You can finish editing the configuration first and install the runtime package afterwards.')),
                    E('pre', { 'style': 'background: #f5f5f5; padding: 10px; border-radius: 4px;' }, 'opkg update\nopkg install phantun')
                ]),
                mapEl
            ]);
        });
    }
});