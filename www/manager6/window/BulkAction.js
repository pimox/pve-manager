Ext.define('PVE.window.BulkAction', {
    extend: 'Ext.window.Window',

    resizable: true,
    width: 800,
    modal: true,
    layout: {
	type: 'fit',
    },
    border: false,

    // the action to be set
    // currently there are
    // startall
    // migrateall
    // stopall
    action: undefined,

    submit: function(params) {
	var me = this;

	Proxmox.Utils.API2Request({
	    params: params,
	    url: '/nodes/' + me.nodename + '/' + me.action,
	    waitMsgTarget: me,
	    method: 'POST',
	    failure: function(response, opts) {
		Ext.Msg.alert('Error', response.htmlStatus);
	    },
	    success: function(response, options) {
		var upid = response.result.data;

		var win = Ext.create('Proxmox.window.TaskViewer', {
		    upid: upid,
		});
		win.show();
		me.hide();
		win.on('destroy', function() {
		    me.close();
		});
	    },
	});
    },

    initComponent: function() {
	var me = this;

	if (!me.nodename) {
	    throw "no node name specified";
	}
	if (!me.action) {
	    throw "no action specified";
	}
	if (!me.btnText) {
	    throw "no button text specified";
	}
	if (!me.title) {
	    throw "no title specified";
	}

	var items = [];

	if (me.action === 'migrateall') {
	    /*value is string and number*/
	    items.push(
		{
		    xtype: 'pveNodeSelector',
		    name: 'target',
		    disallowedNodes: [me.nodename],
		    fieldLabel: gettext('Target node'),
		    allowBlank: false,
		    onlineValidator: true,
		},
		{
		    xtype: 'proxmoxintegerfield',
		    name: 'maxworkers',
		    minValue: 1,
		    maxValue: 100,
		    value: 1,
		    fieldLabel: gettext('Parallel jobs'),
		    allowBlank: false,
		},
		{
		    xtype: 'fieldcontainer',
		    fieldLabel: gettext('Allow local disk migration'),
		    layout: 'hbox',
		    items: [{
			xtype: 'proxmoxcheckbox',
			name: 'with-local-disks',
			checked: true,
			uncheckedValue: 0,
			listeners: {
			    change: (cb, val) => me.down('#localdiskwarning').setVisible(val),
			},

		    },
		    {
			itemId: 'localdiskwarning',
			xtype: 'displayfield',
			flex: 1,
			padding: '0 0 0 10',
			userCls: 'pmx-hint',
			value: 'Note: Migration with local disks might take long.',
		    }],
		},
		{
		    itemId: 'lxcwarning',
		    xtype: 'displayfield',
		    userCls: 'pmx-hint',
		    value: 'Warning: Running CTs will be migrated in Restart Mode.',
		    hidden: true, // only visible if running container chosen
		},
	    );
	} else if (me.action === 'startall') {
	    items.push({
		xtype: 'hiddenfield',
		name: 'force',
		value: 1,
	    });
	}

	items.push({
	    xtype: 'vmselector',
	    itemId: 'vms',
	    name: 'vms',
	    flex: 1,
	    height: 300,
	    selectAll: true,
	    allowBlank: false,
	    nodename: me.nodename,
	    action: me.action,
	    listeners: {
		selectionchange: function(vmselector, records) {
		    if (me.action === 'migrateall') {
			let showWarning = records.some(
			    item => item.data.type === 'lxc' && item.data.status === 'running',
			);
			me.down('#lxcwarning').setVisible(showWarning);
		    }
		},
	    },
	});

	me.formPanel = Ext.create('Ext.form.Panel', {
	    bodyPadding: 10,
	    border: false,
	    layout: {
		type: 'vbox',
		align: 'stretch',
	    },
	    fieldDefaults: {
		labelWidth: 300,
		anchor: '100%',
	    },
	    items: items,
	});

	var form = me.formPanel.getForm();

	var submitBtn = Ext.create('Ext.Button', {
	    text: me.btnText,
	    handler: function() {
		form.isValid();
		me.submit(form.getValues());
	    },
	});

	Ext.apply(me, {
	    items: [me.formPanel],
	    buttons: [submitBtn],
	});

	me.callParent();

	form.on('validitychange', function() {
	    var valid = form.isValid();
	    submitBtn.setDisabled(!valid);
	});
	form.isValid();
    },
});
