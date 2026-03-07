'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require rpc';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function serviceRunning(serviceData) {
	var instances = serviceData?.phantun?.instances || {};
	for (var k in instances)
		if (instances[k]?.running)
			return true;
	return false;
}

function addCommonTunnelOptions(s, mode) {
	var o;

	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default = '0';
	o.rmempty = false;

	o = s.option(form.Value, 'alias', _('Alias'));
	o.placeholder = mode === 'client' ? 'WG Client' : 'VPS Server';
	o.rmempty = false;

	if (mode === 'client') {
		o = s.option(form.Value, 'local_addr', _('Local UDP listen address'));
		o.datatype = 'ipaddr';
		o.placeholder = '127.0.0.1';
		o.rmempty = false;
	}

	o = s.option(form.Value, 'local_port', mode === 'client' ? _('Local listen port') : _('TCP listen port'));
	o.datatype = 'port';
	o.rmempty = false;
	o.placeholder = mode === 'client' ? '51820' : '5245';

	o = s.option(form.Value, 'remote_addr', mode === 'client' ? _('Remote server address') : _('Forward to address'));
	o.placeholder = mode === 'client' ? '158.101.158.68' : '127.0.0.1';
	o.rmempty = false;

	o = s.option(form.Value, 'remote_port', mode === 'client' ? _('Remote server port') : _('Forward to port'));
	o.datatype = 'port';
	o.placeholder = mode === 'client' ? '5245' : '29900';
	o.rmempty = false;

	o = s.option(form.Value, 'tun_name', _('TUN device name'));
	o.placeholder = mode === 'client' ? 'phantun-client0' : 'phantun-server0';

	o = s.option(form.Value, 'tun_local', _('TUN local IPv4'));
	o.datatype = 'ipaddr';
	o.placeholder = mode === 'client' ? '192.168.200.1' : '192.168.201.1';
	o.rmempty = false;

	o = s.option(form.Value, 'tun_peer', _('TUN peer IPv4'));
	o.datatype = 'ipaddr';
	o.placeholder = mode === 'client' ? '192.168.200.2' : '192.168.201.2';
	o.rmempty = false;

	o = s.option(form.Flag, 'ipv4_only', _('IPv4 only'));
	o.default = '0';

	o = s.option(form.Value, 'tun_local6', _('TUN local IPv6'));
	o.placeholder = mode === 'client' ? 'fcc8::1' : 'fcc9::1';
	o.depends('ipv4_only', '0');

	o = s.option(form.Value, 'tun_peer6', _('TUN peer IPv6'));
	o.placeholder = mode === 'client' ? 'fcc8::2' : 'fcc9::2';
	o.depends('ipv4_only', '0');

	o = s.option(form.Value, 'handshake_packet', _('Handshake packet path'));
	o.placeholder = '/etc/phantun/handshake.bin';
}

return view.extend({
	title: _('Phantun Configuration'),

	load: function() {
		return Promise.all([
			L.resolveDefault(uci.load('phantun'), null),
			L.resolveDefault(fs.stat('/usr/bin/phantun_client'), null),
			L.resolveDefault(fs.stat('/usr/bin/phantun_server'), null),
			L.resolveDefault(callServiceList('phantun'), {})
		]);
	},

	render: function(data) {
		var clientBin = data[1] != null;
		var serverBin = data[2] != null;
		var running = serviceRunning(data[3]);
		var m, s, o;
		var nodes = [];

		if (!clientBin || !serverBin) {
			nodes.push(E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, _('Phantun runtime is incomplete. ')),
				_('Expected binaries: /usr/bin/phantun_client and /usr/bin/phantun_server')
			]));
		}

		nodes.push(E('div', { 'class': 'cbi-section' }, [
			E('p', {}, [
				_('Service state: '),
				E('strong', {}, running ? _('running') : _('stopped')),
				' · ',
				_('Client binary: '), E('strong', {}, clientBin ? _('present') : _('missing')),
				' · ',
				_('Server binary: '), E('strong', {}, serverBin ? _('present') : _('missing'))
			])
		]));

		m = new form.Map('phantun', _('Phantun'),
			_('M1 delivery skeleton: global settings, client/server tunnel definitions, and basic runtime visibility.'));

		s = m.section(form.NamedSection, 'general', 'general', _('Global settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable service'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		['trace', 'debug', 'info', 'warn', 'error'].forEach(function(v) {
			o.value(v, v);
		});
		o.default = 'info';
		o.rmempty = false;

		o = s.option(form.Flag, 'wait_lock', _('Use iptables -w'));
		o.default = '0';

		o = s.option(form.Flag, 'retry_on_error', _('Respawn on failure'));
		o.default = '0';

		s = m.section(form.GridSection, 'client', _('Client tunnels'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		addCommonTunnelOptions(s, 'client');

		s = m.section(form.GridSection, 'server', _('Server tunnels'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		addCommonTunnelOptions(s, 'server');

		nodes.push(m.render());
		return E([], nodes);
	}
});
