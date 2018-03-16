Ext.define('PVE.storage.CIFSScan', {
    extend: 'Ext.form.field.ComboBox',
    alias: 'widget.pveCIFSScan',

    queryParam: 'server',

    valueField: 'share',
    displayField: 'share',
    matchFieldWidth: false,
    listConfig: {
	loadingText: gettext('Scanning...'),
	width: 350
    },
    doRawQuery: function() {
    },

    onTriggerClick: function() {
	var me = this;

	if (!me.queryCaching || me.lastQuery !== me.cifsServer) {
	    me.store.removeAll();
	}

	var params = {};
	if (me.cifsUsername && me.cifsPassword) {
	    params.username =  me.cifsUsername;
	    params.password = me.cifsPassword;
	}

	if (me.cifsDomain) {
	    params.domain = me.cifsDomain;
	}

	me.store.getProxy().setExtraParams(params);
	me.allQuery = me.cifsServer;

	me.callParent();
    },

    setServer: function(server) {
	var me = this;

	me.cifsServer = server;
    },

    setUsername: function(username) {
	var me = this;

	me.cifsUsername = username;
    },

    setPassword: function(password) {
	var me = this;

	me.cifsPassword = password;
    },

    setDomain: function(domain) {
	var me = this;

	me.cifsDomain = domain;
    },

    initComponent : function() {
	var me = this;

	if (!me.nodename) {
	    me.nodename = 'localhost';
	}

	var store = Ext.create('Ext.data.Store', {
	    fields: ['description', 'share'],
	    proxy: {
		type: 'proxmox',
		url: '/api2/json/nodes/' + me.nodename + '/scan/cifs'
	    }
	});
	store.sort('share', 'ASC');

	Ext.apply(me, {
	    store: store
	});

	me.callParent();
    }
});

Ext.define('PVE.storage.CIFSInputPanel', {
    extend: 'Proxmox.panel.InputPanel',
    controller: 'storageEdit',

    onGetValues: function(values) {
	var me = this;

	if (me.isCreate) {
	    values.type = 'cifs';
	} else {
	    delete values.storage;
	}

	values.disable = values.enable ? 0 : 1;
	delete values.enable;

	return values;
    },

    initComponent : function() {
	var me = this;

	var passwordfield = Ext.createWidget(me.isCreate ? 'textfield' : 'displayfield', {
	    inputType: 'password',
	    name: 'password',
	    value: me.isCreate ? '' : '********',
	    fieldLabel: gettext('Password'),
	    allowBlank: true,
	    minLength: 1,
	    listeners: {
		change: function(f, value) {

		    if (me.isCreate) {
			var exportField = me.down('field[name=share]');
			exportField.setPassword(value);
		    }
		}
	    }
	});

	me.column1 = [
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'storage',
		value: me.storageId || '',
		fieldLabel: 'ID',
		vtype: 'StorageId',
		allowBlank: false
	    },
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'server',
		value: '',
		fieldLabel: gettext('Server'),
		allowBlank: false,
		listeners: {
		    change: function(f, value) {
			if (me.isCreate) {
			    var exportField = me.down('field[name=share]');
			    exportField.setServer(value);
			}
		    }
		}
	    },
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'username',
		value: '',
		fieldLabel: gettext('Username'),
		emptyText: gettext('Guest user'),
		allowBlank: true,
		listeners: {
		    change: function(f, value) {
			if (me.isCreate) {
			    var exportField = me.down('field[name=share]');
			    exportField.setUsername(value);
			}
			if (value == "") {
			    passwordfield.allowBlank = true;
			} else {
			    passwordfield.allowBlank = false;
			}
			passwordfield.validate();
		    }
		}
	    },
	    {
		xtype: me.isCreate ? 'pveCIFSScan' : 'displayfield',
		name: 'share',
		value: '',
		fieldLabel: 'Share',
		allowBlank: false
	    },
	    {
		xtype: 'pveContentTypeSelector',
		name: 'content',
		value: 'images',
		multiSelect: true,
		fieldLabel: gettext('Content'),
		allowBlank: false
	    }
	];

	me.column2 = [
	    {
		xtype: 'pveNodeSelector',
		name: 'nodes',
		fieldLabel: gettext('Nodes'),
		emptyText: gettext('All') + ' (' +
		    gettext('No restrictions') +')',
		multiSelect: true,
		autoSelect: false
	    },
	    {
		xtype: 'proxmoxcheckbox',
		name: 'enable',
		checked: true,
		uncheckedValue: 0,
		fieldLabel: gettext('Enable')
	    },
	    {
		xtype: 'proxmoxintegerfield',
		fieldLabel: gettext('Max Backups'),
		name: 'maxfiles',
		reference: 'maxfiles',
		minValue: 0,
		maxValue: 365,
		value: me.isCreate ? '1' : undefined,
		allowBlank: false
	    },
	    passwordfield,
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'domain',
		value: me.isCreate ? '' : undefined,
		fieldLabel: gettext('Domain'),
		allowBlank: true,
		listeners: {
		    change: function(f, value) {
			if (me.isCreate) {

			    var exportField = me.down('field[name=share]');
			    exportField.setDomain(value);
			}
		    }
		}
	    }
	];

	me.callParent();
    }
});

Ext.define('PVE.storage.CIFSEdit', {
    extend: 'Proxmox.window.Edit',

    initComponent : function() {
	var me = this;

	me.isCreate = !me.storageId;

	if (me.isCreate) {
            me.url = '/api2/extjs/storage';
            me.method = 'POST';
        } else {
            me.url = '/api2/extjs/storage/' + me.storageId;
            me.method = 'PUT';
        }

	var ipanel = Ext.create('PVE.storage.CIFSInputPanel', {
	    isCreate: me.isCreate,
	    storageId: me.storageId
	});

	Ext.apply(me, {
            subject: 'CIFS',
	    isAdd: true,
	    items: [ ipanel ]
	});

	me.callParent();

	if (!me.isCreate) {
	    me.load({
		success:  function(response, options) {
		    var values = response.result.data;
		    var ctypes = values.content || '';

		    values.content = ctypes.split(',');

		    if (values.nodes) {
			values.nodes = values.nodes.split(',');
		    }
		    values.enable = values.disable ? 0 : 1;
		    ipanel.setValues(values);
		}
	    });
	}
    }
});
