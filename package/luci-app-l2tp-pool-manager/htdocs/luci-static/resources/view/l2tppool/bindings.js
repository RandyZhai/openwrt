'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('l2tppool', _('SSID Bindings'),
			_('Each binding creates an independent LAN segment + SSID, and binds it to a chosen L2TP account via a PBR policy. Save here, then click Apply config on the Overview page.'));

		// ---- bindings ----
		s = m.section(form.GridSection, 'binding', _('SSID bindings'));
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		s.modaltitle = _('SSID binding');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.editable = true;
		o = s.option(form.Value, 'ssid', _('SSID'));
		o.placeholder = 'SSID-01';
		o.editable = true;
		o = s.option(form.Value, 'network', _('Interface name'));
		o.placeholder = 'lan10';
		o.datatype = 'and(uciname,maxlength(15))';
		o.editable = true;
		o = s.option(form.Value, 'subnet', _('Subnet (CIDR)'));
		o.placeholder = '192.168.10.0/24';
		o.datatype = 'cidr';
		o.editable = true;
		o = s.option(form.ListValue, 'account', _('L2TP account'));
		o.editable = true;
		o.cfgvalue = function (section_id) {
			var accs = uci.sections('l2tppool', 'account') || [];
			accs.forEach(function (a) {
				o.value(a['.name'], (a.name || a['.name']));
			});
			return uci.get('l2tppool', section_id, 'account');
		};
		o = s.option(form.ListValue, 'rotate_mode', _('Rotate mode'));
		o.value('manual', 'Manual');
		o.value('round_robin', 'Round Robin');
		o.value('random', 'Random');

		// ---- pools ----
		s = m.section(form.TypedSection, 'pool', _('Account pools'));
		s.addremove = true;
		s.anonymous = false;
		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o = s.option(form.Value, 'mode', _('Mode'));
		o.value('round_robin', 'Round Robin');
		o.value('random', 'Random');
		o.value('switch', 'Switch');
		o = s.option(form.DynamicList, 'account', _('Accounts in pool'));

		return m.render();
	}
});
