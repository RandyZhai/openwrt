'use strict';
'require view';
'require form';

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('l2tppool', _('L2TP Accounts'),
			_('Add/remove L2TP dial accounts. Each becomes an independent interface (proto l2tp, defaultroute=0). Save here, then click Apply config on the Overview page to generate the interfaces.'));

		// ---- global ----
		s = m.section(form.TypedSection, 'global', _('Global settings'));
		s.addremove = false;
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o = s.option(form.Value, 'ip_check_url', _('IP check URL'));
		o.placeholder = 'https://api.ipify.org';
		o = s.option(form.Value, 'redial_wait', _('Redial wait (s)'));
		o.datatype = 'uinteger';
		o.placeholder = '3';
		o = s.option(form.ListValue, 'rotate_mode', _('Default rotate mode'));
		o.value('round_robin', 'Round Robin');
		o.value('random', 'Random');
		o.value('switch', 'Switch');

		// ---- accounts ----
		s = m.section(form.GridSection, 'account', _('L2TP accounts'));
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		s.sortable = true;
		s.modaltitle = _('L2TP account');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.editable = true;
		o = s.option(form.Value, 'name', _('Interface name'));
		o.placeholder = 'l2tp_001';
		o.datatype = 'and(uciname,maxlength(15))';
		o.editable = true;
		o = s.option(form.Value, 'server', _('Server'));
		o.datatype = 'host';
		o.editable = true;
		o = s.option(form.Value, 'username', _('Username'));
		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;
		o = s.option(form.Value, 'group', _('Pool'));
		o.placeholder = 'default';
		o = s.option(form.Value, 'metric', _('Metric'));
		o.datatype = 'uinteger';
		o.placeholder = '101';
		o = s.option(form.Value, 'mtu', _('MTU'));
		o.datatype = 'range(576,1500)';
		o.placeholder = '1400';

		return m.render();
	}
});
