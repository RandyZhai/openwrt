'use strict';
'require view';
'require fs';
'require ui';

var SCRIPT = '/usr/libexec/l2tppool.sh';

return view.extend({
	render: function () {
		var out = E('textarea', {
			'class': 'cbi-input-textarea',
			style: 'width:100%;height:440px;font-family:monospace;font-size:12px',
			readonly: true
		});

		function append(msg) { out.value = (out.value ? out.value + '\n' : '') + msg; }

		function refresh() {
			out.value = _('Loading...');
			return fs.exec(SCRIPT, ['diagnostics']).then(function (res) {
				out.value = ((res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')) || _('no output');
			});
		}

		var ifInput = E('input', { 'class': 'cbi-input-text', placeholder: 'l2tp_001', style: 'width:160px' });
		var ipBtn = E('button', { 'class': 'cbi-button', click: function () {
			var v = (ifInput.value || '').trim();
			if (!v) return;
			append('\n$ ipcheck ' + v);
			fs.exec(SCRIPT, ['ipcheck', v]).then(function (res) {
				append((res.stdout || res.stderr || '').trim() || _('failed'));
			});
		} }, _('Check IP'));

		var refreshBtn = E('button', { 'class': 'cbi-button cbi-button-positive', click: refresh }, _('Refresh diagnostics'));

		refresh();

		return E('div', {}, [
			E('div', { 'class': 'cbi-map-descr' }, _('Inspect generated network/wireless/pbr config, routes, interface states and recent logs. Use ipcheck to probe a single interface public IP.')),
			E('div', { 'class': 'cbi-section' }, [ifInput, ' ', ipBtn, ' ', refreshBtn]),
			out
		]);
	}
});
