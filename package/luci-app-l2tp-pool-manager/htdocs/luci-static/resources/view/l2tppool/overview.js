'use strict';
'require view';
'require fs';
'require ui';

var SCRIPT = '/usr/libexec/l2tppool.sh';

function run(cmd, args) {
	return fs.exec(SCRIPT, [cmd].concat(args || []));
}

return view.extend({
	title: _('L2TP Pool - Overview'),

	load: function () {
		return run('status').then(function (res) {
			try { return JSON.parse(res.stdout); }
			catch (e) { return { accounts: [], bindings: [] }; }
		});
	},

	render: function (data) {
		var self = this;
		var bindings = (data && data.bindings) || [];

		function statusBadge(s) {
			var map = {
				online: ['#0a0', _('Online')],
				offline: ['#c00', _('Offline')],
				dialing: ['#e80', _('Dialing')]
			};
			var m = map[s] || ['#888', s || '-'];
			return E('span', { style: 'color:' + m[0] + ';font-weight:bold' }, m[1]);
		}

		function act(cmd, args, label) {
			ui.showModal(label, [E('p', {}, _('Running, please wait...'))]);
			return run(cmd, args).then(function (res) {
				var msg = ((res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')).trim() || _('Done');
				ui.showModal(label, [
					E('pre', { style: 'max-height:260px;overflow:auto;white-space:pre-wrap' }, msg),
					E('div', { 'class': 'right' }, E('button', {
						'class': 'btn cbi-button-positive',
						click: function () { ui.hideModal(); location.reload(); }
					}, _('OK')))
				]);
			});
		}

		var rows;
		if (bindings.length === 0) {
			rows = [E('tr', {}, E('td', { colspan: 7, style: 'text-align:center' }, _('No bindings configured. Add them under SSID Bindings and click Apply config.')))];
		} else {
			rows = bindings.map(function (b) {
				return E('tr', {}, [
					E('td', {}, b.ssid || '-'),
					E('td', {}, b.subnet || '-'),
					E('td', {}, b.account || '-'),
					E('td', {}, b.interface || '-'),
					E('td', {}, b.public_ip || _('—')),
					E('td', {}, statusBadge(b.status)),
					E('td', {}, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							click: function () { act('redial', [b.account], _('Redial ') + (b.account || '')); }
						}, _('Redial')),
						' ',
						E('button', {
							'class': 'cbi-button cbi-button-action',
							click: function () { act('rotate', [b.id], _('Rotate ') + (b.ssid || b.id)); }
						}, _('Rotate'))
					])
				]);
			});
		}

		var table = E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, [
				E('th', {}, _('SSID')),
				E('th', {}, _('Subnet')),
				E('th', {}, _('Account')),
				E('th', {}, _('Interface')),
				E('th', {}, _('Public IP')),
				E('th', {}, _('Status')),
				E('th', {}, _('Actions'))
			])),
			E('tbody', {}, rows)
		]);

		var toolbar = E('div', { 'class': 'cbi-section' }, [
			E('button', { 'class': 'cbi-button cbi-button-positive', click: function () { location.reload(); } }, _('Refresh status')),
			E('button', { 'class': 'cbi-button', click: function () { act('apply', [], _('Apply config')); } }, _('Apply config')),
			E('button', { 'class': 'cbi-button', click: function () { act('rotate_all', [], _('Rotate all')); } }, _('Rotate all'))
		]);

		return E('div', {}, [
			E('div', { 'class': 'cbi-map-descr' }, _('One-glance view of every SSID, its bound L2TP egress, current public IP and connection state. Apply config regenerates network/wireless/pbr from /etc/config/l2tppool.')),
			toolbar, table
		]);
	}
});
