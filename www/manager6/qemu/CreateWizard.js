Ext.define('PVE.qemu.CreateWizard', {
    extend: 'PVE.window.Wizard',
    alias: 'widget.pveQemuCreateWizard',
    mixins: ['Proxmox.Mixin.CBind'],

    viewModel: {
	data: {
	    nodename: '',
	    current: {
		scsihw: '',
	    },
	},
    },

    cbindData: {
	nodename: undefined,
    },

    subject: gettext('Virtual Machine'),

    items: [
	{
	    xtype: 'inputpanel',
	    title: gettext('General'),
	    onlineHelp: 'qm_general_settings',
	    column1: [
		{
		    xtype: 'pveNodeSelector',
		    name: 'nodename',
		    cbind: {
			selectCurNode: '{!nodename}',
			preferredValue: '{nodename}',
		    },
		    bind: {
			value: '{nodename}',
		    },
		    fieldLabel: gettext('Node'),
		    allowBlank: false,
		    onlineValidator: true,
		},
		{
		    xtype: 'pveGuestIDSelector',
		    name: 'vmid',
		    guestType: 'qemu',
		    value: '',
		    loadNextFreeID: true,
		    validateExists: false,
		},
		{
		    xtype: 'textfield',
		    name: 'name',
		    vtype: 'DnsName',
		    value: '',
		    fieldLabel: gettext('Name'),
		    allowBlank: true,
		},
	    ],
	    column2: [
		{
		    xtype: 'pvePoolSelector',
		    fieldLabel: gettext('Resource Pool'),
		    name: 'pool',
		    value: '',
		    allowBlank: true,
		},
	    ],
	    advancedColumn1: [
		{
		    xtype: 'proxmoxcheckbox',
		    name: 'onboot',
		    uncheckedValue: 0,
		    defaultValue: 0,
		    deleteDefaultValue: true,
		    fieldLabel: gettext('Start at boot'),
		},
	    ],
	    advancedColumn2: [
		{
		    xtype: 'textfield',
		    name: 'order',
		    defaultValue: '',
		    emptyText: 'any',
		    labelWidth: 120,
		    fieldLabel: gettext('Start/Shutdown order'),
		},
		{
		    xtype: 'textfield',
		    name: 'up',
		    defaultValue: '',
		    emptyText: 'default',
		    labelWidth: 120,
		    fieldLabel: gettext('Startup delay'),
		},
		{
		    xtype: 'textfield',
		    name: 'down',
		    defaultValue: '',
		    emptyText: 'default',
		    labelWidth: 120,
		    fieldLabel: gettext('Shutdown timeout'),
		},
	    ],
	    onGetValues: function(values) {
		['name', 'pool', 'onboot', 'agent'].forEach(function(field) {
		    if (!values[field]) {
			delete values[field];
		    }
		});

		var res = PVE.Parser.printStartup({
		    order: values.order,
		    up: values.up,
		    down: values.down,
		});

		if (res) {
		    values.startup = res;
		}

		delete values.order;
		delete values.up;
		delete values.down;

		return values;
	    },
	},
	{
	    xtype: 'container',
	    layout: 'hbox',
	    defaults: {
		flex: 1,
		padding: '0 10',
	    },
	    title: gettext('OS'),
	    items: [
		{
		    xtype: 'pveQemuCDInputPanel',
		    bind: {
			nodename: '{nodename}',
		    },
		    confid: 'ide2',
		    insideWizard: true,
		},
		{
		    xtype: 'pveQemuOSTypePanel',
		    insideWizard: true,
		},
	    ],
	},
	{
	    xtype: 'pveQemuSystemPanel',
	    title: gettext('System'),
	    isCreate: true,
	    insideWizard: true,
	},
	{
	    xtype: 'pveQemuHDInputPanel',
	    padding: 0,
	    bind: {
		nodename: '{nodename}',
	    },
	    title: gettext('Hard Disk'),
	    isCreate: true,
	    insideWizard: true,
	},
	{
	    xtype: 'pveQemuProcessorPanel',
	    insideWizard: true,
	    title: gettext('CPU'),
	},
	{
	    xtype: 'pveQemuMemoryPanel',
	    insideWizard: true,
	    title: gettext('Memory'),
	},
	{
	    xtype: 'pveQemuNetworkInputPanel',
	    bind: {
		nodename: '{nodename}',
	    },
	    title: gettext('Network'),
	    insideWizard: true,
	},
	{
	    title: gettext('Confirm'),
	    layout: 'fit',
	    items: [
		{
		    xtype: 'grid',
		    store: {
			model: 'KeyValue',
			sorters: [{
			    property: 'key',
			    direction: 'ASC',
			}],
		    },
		    columns: [
			{ header: 'Key', width: 150, dataIndex: 'key' },
			{ header: 'Value', flex: 1, dataIndex: 'value' },
		    ],
		},
	    ],
	    dockedItems: [
		{
		    xtype: 'proxmoxcheckbox',
		    name: 'start',
		    dock: 'bottom',
		    margin: '5 0 0 0',
		    boxLabel: gettext('Start after created'),
		},
	    ],
	    listeners: {
		show: function(panel) {
		    var kv = this.up('window').getValues();
		    var data = [];
		    Ext.Object.each(kv, function(key, value) {
			if (key === 'delete') { // ignore
			    return;
			}
			data.push({ key: key, value: value });
		    });

		    var summarystore = panel.down('grid').getStore();
		    summarystore.suspendEvents();
		    summarystore.removeAll();
		    summarystore.add(data);
		    summarystore.sort();
		    summarystore.resumeEvents();
		    summarystore.fireEvent('refresh');
		},
	    },
	    onSubmit: function() {
		var wizard = this.up('window');
		var kv = wizard.getValues();
		delete kv.delete;

		var nodename = kv.nodename;
		delete kv.nodename;

		Proxmox.Utils.API2Request({
		    url: '/nodes/' + nodename + '/qemu',
		    waitMsgTarget: wizard,
		    method: 'POST',
		    params: kv,
		    success: function(response) {
			wizard.close();
		    },
		    failure: function(response, opts) {
			Ext.Msg.alert(gettext('Error'), response.htmlStatus);
		    },
		});
	    },
	},
    ],
});


