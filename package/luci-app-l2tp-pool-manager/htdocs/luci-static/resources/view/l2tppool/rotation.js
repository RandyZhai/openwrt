'use strict';
'require view';
'require fs';
'require ui';

var SCRIPT = '/usr/libexec/l2tppool.sh';

function run(cmd, args) {
	return fs.exec(SCRIPT, [cmd].concat(args || []));
}

return view.extend({
	load: function () {
		return run('status').then(function (res) {
			try { return JSON.parse(res.stdout); }
			catch (e) { return { bindings: [] }; }
		});
	},

	render: function (data) {
		var bindings = (data && data.bindings) || [];

		var logBox = E('textarea', {
			'class': 'cbi-input-textarea',
			style: 'width:100%;height:220px;font-family:monospace',
			readonly: true
		});

		function log(msg) {
			var ts = new Date().toLocaleTimeString();
			logBox.value += '[' + ts + '] ' + msg + '\n';
			logBox.scrollTop = logBox.scrollHeight;
		}

		function rot(id, ssid) {
			ui.showModal(_('Rotate ') + (ssid || id), [E('p', {}, _('Rotating, please wait...'))]);
			return run('rotate', [id]).then(function (res) {
				ui.hideModal();
				log('> rotate ' + (ssid || id) + ': ' + ((res.stdout || res.stderr || '').trim() || _('no output')));
			});
		}

		function rotAll() {
			ui.showModal(_('Rotate all'), [E('p', {}, _('Rotating all bindings...'))]);
			return run('rotate_all').then(function (res) {
				ui.hideModal();
				log(((res.stdout || res.stderr || '').trim()) || _('done'));
			});
		}

		var rows;
		if (bindings.length === 0) {
			rows = [E('tr', {}, E('td', { colspan: 5, style: 'text-align:center' }, _('No bindings configured.')))];
		} else {
			rows = bindings.map(function (b) {
				return E('tr', {}, [
					E('td', {}, b.ssid || '-'),
					E('td', {}, b.subnet || '-'),
					E('td', {}, b.account || '-'),
					E('td', {}, b.interface || '-'),
					E('td', {}, E('button', {
						'class': 'cbi-button cbi-button-action',
						click: function () { rot(b.id, b.ssid); }
					}, _('Rotate')))
				]);
			});
		}

		var table = E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, [
				E('th', {}, _('SSID')),
				E('th', {}, _('Subnet')),
				E('th', {}, _('Current account')),
				E('th', {}, _('Interface')),
				E('th', {}, _('Action'))
			])),
			E('tbody', {}, rows)
		]);

		var toolbar = E('div', { 'class': 'cbi-section' }, [
			E('button', { 'class': 'cbi-button cbi-button-positive', click: rotAll }, _('Rotate all')),
			E('button', { 'class': 'cbi-button', click: function () { logBox.value = ''; } }, _('Clear log'))
		]);

		return E('div', {}, [
			E('div', { 'class': 'cbi-map-descr' }, _('Switch a SSID from its current L2TP account to the next enabled account in the pool. PBR is updated and the new egress IP is probed automatically.')),
			table, toolbar,
			E('h3', {}, _('Rotation log')),
			logBox
		]);
	}
});
