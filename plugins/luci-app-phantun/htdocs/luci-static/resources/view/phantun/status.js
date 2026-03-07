'use strict';
'require view';
'require uci';
'require fs';
'require rpc';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function normalizeInstances(serviceData) {
	var out = [];
	var instances = serviceData?.phantun?.instances || {};

	for (var name in instances) {
		out.push({
			name: name,
			running: !!instances[name]?.running,
			pid: instances[name]?.pid || '-',
			command: Array.isArray(instances[name]?.command) ? instances[name].command.join(' ') : '-'
		});
	}

	return out;
}

function renderKV(label, value) {
	return E('div', { 'style': 'margin: .35rem 0;' }, [
		E('strong', { 'style': 'display:inline-block; min-width: 12rem;' }, label + ':'),
		E('span', {}, value)
	]);
}

return view.extend({
	title: _('Phantun Status'),

	load: function() {
		return Promise.all([
			L.resolveDefault(uci.load('phantun'), null),
			L.resolveDefault(fs.stat('/usr/bin/phantun_client'), null),
			L.resolveDefault(fs.stat('/usr/bin/phantun_server'), null),
			L.resolveDefault(callServiceList('phantun'), {}),
			L.resolveDefault(fs.exec('/bin/sh', ['-c', 'pgrep -af "phantun_(client|server)" || true']), { stdout: '' })
		]);
	},

	render: function(data) {
		var clientBin = data[1] != null;
		var serverBin = data[2] != null;
		var instances = normalizeInstances(data[3]);
		var processList = (data[4]?.stdout || '').trim();
		var sections = uci.sections('phantun') || [];
		var clientCount = sections.filter(function(s) { return s['.type'] === 'client'; }).length;
		var serverCount = sections.filter(function(s) { return s['.type'] === 'server'; }).length;
		var enabled = uci.get('phantun', 'general', 'enabled') === '1';
		var children = [];

		children.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Runtime summary')),
			renderKV(_('Service enabled'), enabled ? _('yes') : _('no')),
			renderKV(_('Client binary'), clientBin ? _('present') : _('missing')),
			renderKV(_('Server binary'), serverBin ? _('present') : _('missing')),
			renderKV(_('Configured client tunnels'), String(clientCount)),
			renderKV(_('Configured server tunnels'), String(serverCount)),
			renderKV(_('Running instances'), String(instances.length))
		]));

		children.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('procd instances')),
			instances.length ? E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Instance')),
					E('th', { 'class': 'th' }, _('Running')),
					E('th', { 'class': 'th' }, _('PID')),
					E('th', { 'class': 'th' }, _('Command'))
				])
			].concat(instances.map(function(inst) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, inst.name),
					E('td', { 'class': 'td' }, inst.running ? _('yes') : _('no')),
					E('td', { 'class': 'td' }, String(inst.pid)),
					E('td', { 'class': 'td', 'style': 'word-break: break-all;' }, inst.command)
				]);
			}))) : E('p', {}, _('No procd instances reported yet.'))
		]));

		children.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Process probe')),
			E('pre', { 'style': 'white-space: pre-wrap;' }, processList || _('No matching processes found.'))
		]));

		children.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('M1 scope note')),
			E('p', {}, _('This page is the first delivery skeleton. It verifies binary presence, UCI model loading, and runtime process visibility. Detailed tunnel diagnostics and log panels will be added in later milestones.'))
		]));

		return E([], children);
	}
});
