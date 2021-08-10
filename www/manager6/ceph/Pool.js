Ext.define('PVE.CephPoolInputPanel', {
    extend: 'Proxmox.panel.InputPanel',
    xtype: 'pveCephPoolInputPanel',
    mixins: ['Proxmox.Mixin.CBind'],

    showProgress: true,
    onlineHelp: 'pve_ceph_pools',

    subject: 'Ceph Pool',
    column1: [
	{
	    xtype: 'pmxDisplayEditField',
	    fieldLabel: gettext('Name'),
	    cbind: {
		editable: '{isCreate}',
		value: '{pool_name}',
	    },
	    name: 'name',
	    allowBlank: false,
	},
	{
	    xtype: 'proxmoxintegerfield',
	    fieldLabel: gettext('Size'),
	    name: 'size',
	    value: 3,
	    minValue: 2,
	    maxValue: 7,
	    allowBlank: false,
	    listeners: {
		change: function(field, val) {
		    let size = Math.round(val / 2);
		    if (size > 1) {
			field.up('inputpanel').down('field[name=min_size]').setValue(size);
		    }
		},
	    },
	},
    ],
    column2: [
	{
	    xtype: 'proxmoxKVComboBox',
	    fieldLabel: 'PG Autoscale Mode',
	    name: 'pg_autoscale_mode',
	    comboItems: [
		['warn', 'warn'],
		['on', 'on'],
		['off', 'off'],
	    ],
	    value: 'on', // FIXME: check ceph version and only default to on on octopus and newer
	    allowBlank: false,
	    autoSelect: false,
	    labelWidth: 140,
	},
	{
	    xtype: 'proxmoxcheckbox',
	    fieldLabel: gettext('Add as Storage'),
	    cbind: {
		value: '{isCreate}',
		hidden: '{!isCreate}',
	    },
	    name: 'add_storages',
	    labelWidth: 140,
	    autoEl: {
		tag: 'div',
		'data-qtip': gettext('Add the new pool to the cluster storage configuration.'),
	    },
	},
    ],
    advancedColumn1: [
	{
	    xtype: 'proxmoxintegerfield',
	    fieldLabel: gettext('Min. Size'),
	    name: 'min_size',
	    value: 2,
	    cbind: {
		minValue: (get) => get('isCreate') ? 2 : 1,
	    },
	    maxValue: 7,
	    allowBlank: false,
	    listeners: {
		change: function(field, minSize) {
		    let panel = field.up('inputpanel');
		    let size = panel.down('field[name=size]').getValue();

		    let showWarning = minSize < (size / 2) && minSize !== size;

		    let fieldLabel = gettext('Min. Size');
		    if (showWarning) {
			fieldLabel = gettext('Min. Size') + ' <i class="fa fa-exclamation-triangle warning"></i>';
		    }
		    panel.down('field[name=min_size-warning]').setHidden(!showWarning);
		    field.setFieldLabel(fieldLabel);
		},
	    },
	},
	{
	    xtype: 'displayfield',
	    name: 'min_size-warning',
	    userCls: 'pmx-hint',
	    value: gettext('min_size < size/2 can lead to data loss, incomplete PGs or unfound objects.'),
	    hidden: true,
	},
	{
	    xtype: 'pveCephRuleSelector',
	    fieldLabel: 'Crush Rule', // do not localize
	    name: 'crush_rule',
	    cbind: {
		nodename: '{nodename}',
		isCreate: '{isCreate}',
	    },
	    allowBlank: false,
	},
	{
	    xtype: 'proxmoxintegerfield',
	    fieldLabel: '# of PGs',
	    name: 'pg_num',
	    value: 128,
	    minValue: 1,
	    maxValue: 32768,
	    allowBlank: false,
	    emptyText: 128,
	},
    ],
    advancedColumn2: [
	{
	    xtype: 'numberfield',
	    fieldLabel: gettext('Target Ratio'),
	    name: 'target_size_ratio',
	    minValue: 0,
	    decimalPrecision: 3,
	    allowBlank: true,
	    emptyText: '0.0',
	    autoEl: {
		tag: 'div',
		'data-qtip': gettext('The ratio of storage amount this pool will consume compared to other pools with ratios. Used for auto-scaling.'),
	    },
	},
	{
	    xtype: 'pveSizeField',
	    name: 'target_size',
	    fieldLabel: gettext('Target Size'),
	    unit: 'GiB',
	    minValue: 0,
	    allowBlank: true,
	    allowZero: true,
	    emptyText: '0',
	    emptyValue: 0,
	    autoEl: {
		tag: 'div',
		'data-qtip': gettext('The amount of data eventually stored in this pool. Used for auto-scaling.'),
	    },
	},
	{
	    xtype: 'displayfield',
	    userCls: 'pmx-hint',
	    value: Ext.String.format(gettext('{0} takes precedence.'), gettext('Target Ratio')), // FIXME: tooltip?
	},
	{
	    xtype: 'proxmoxintegerfield',
	    fieldLabel: 'Min. # of PGs',
	    name: 'pg_num_min',
	    minValue: 0,
	    allowBlank: true,
	    emptyText: '0',
	},
    ],

    onGetValues: function(values) {
	Object.keys(values || {}).forEach(function(name) {
	    if (values[name] === '') {
		delete values[name];
	    }
	});

	return values;
    },
});

Ext.define('PVE.Ceph.PoolEdit', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveCephPoolEdit',
    mixins: ['Proxmox.Mixin.CBind'],

    cbindData: {
	pool_name: '',
	isCreate: (cfg) => !cfg.pool_name,
    },

    cbind: {
	autoLoad: get => !get('isCreate'),
	url: get => get('isCreate')
	    ? `/nodes/${get('nodename')}/ceph/pools`
	    : `/nodes/${get('nodename')}/ceph/pools/${get('pool_name')}`,
	method: get => get('isCreate') ? 'POST' : 'PUT',
    },

    showProgress: true,

    subject: gettext('Ceph Pool'),

    items: [{
	xtype: 'pveCephPoolInputPanel',
	cbind: {
	    nodename: '{nodename}',
	    pool_name: '{pool_name}',
	    isCreate: '{isCreate}',
	},
    }],
});

Ext.define('PVE.node.Ceph.PoolList', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveNodeCephPoolList',

    onlineHelp: 'chapter_pveceph',

    stateful: true,
    stateId: 'grid-ceph-pools',
    bufferedRenderer: false,

    features: [{ ftype: 'summary' }],

    columns: [
	{
	    text: gettext('Name'),
	    minWidth: 120,
	    flex: 2,
	    sortable: true,
	    dataIndex: 'pool_name',
	},
	{
	    text: gettext('Size') + '/min',
	    minWidth: 100,
	    flex: 1,
	    align: 'right',
	    renderer: (v, meta, rec) => `${v}/${rec.data.min_size}`,
	    dataIndex: 'size',
	},
	{
	    text: '# of Placement Groups',
	    flex: 1,
	    minWidth: 100,
	    align: 'right',
	    dataIndex: 'pg_num',
	},
	{
	    text: gettext('Optimal # of PGs'),
	    flex: 1,
	    minWidth: 100,
	    align: 'right',
	    dataIndex: 'pg_num_final',
	    renderer: function(value, metaData) {
		if (!value) {
		    value = '<i class="fa fa-info-circle faded"></i> n/a';
		    metaData.tdAttr = 'data-qtip="Needs pg_autoscaler module enabled."';
		}
		return value;
	    },
	},
	{
	    text: gettext('Min. # of PGs'),
	    flex: 1,
	    minWidth: 100,
	    align: 'right',
	    dataIndex: 'pg_num_min',
	    hidden: true,
	},
	{
	    text: gettext('Target Ratio'),
	    flex: 1,
	    minWidth: 100,
	    align: 'right',
	    dataIndex: 'target_size_ratio',
	    renderer: Ext.util.Format.numberRenderer('0.0000'),
	    hidden: true,
	},
	{
	    text: gettext('Target Size'),
	    flex: 1,
	    minWidth: 100,
	    align: 'right',
	    dataIndex: 'target_size',
	    hidden: true,
	    renderer: function(v, metaData, rec) {
		let value = Proxmox.Utils.render_size(v);
		if (rec.data.target_size_ratio > 0) {
		    value = '<i class="fa fa-info-circle faded"></i> ' + value;
		    metaData.tdAttr = 'data-qtip="Target Size Ratio takes precedence over Target Size."';
		}
		return value;
	    },
	},
	{
	    text: gettext('Autoscale Mode'),
	    flex: 1,
	    minWidth: 100,
	    align: 'right',
	    dataIndex: 'pg_autoscale_mode',
	},
	{
	    text: 'CRUSH Rule (ID)',
	    flex: 1,
	    align: 'right',
	    minWidth: 150,
	    renderer: (v, meta, rec) => `${v} (${rec.data.crush_rule})`,
	    dataIndex: 'crush_rule_name',
	},
	{
	    text: gettext('Used') + ' (%)',
	    flex: 1,
	    minWidth: 150,
	    sortable: true,
	    align: 'right',
	    dataIndex: 'bytes_used',
	    summaryType: 'sum',
	    summaryRenderer: Proxmox.Utils.render_size,
	    renderer: function(v, meta, rec) {
		let percentage = Ext.util.Format.percent(rec.data.percent_used, '0.00');
		let used = Proxmox.Utils.render_size(v);
		return `${used} (${percentage})`;
	    },
	},
    ],
    initComponent: function() {
        var me = this;

	var nodename = me.pveSelNode.data.node;
	if (!nodename) {
	    throw "no node name specified";
	}

	var sm = Ext.create('Ext.selection.RowModel', {});

	var rstore = Ext.create('Proxmox.data.UpdateStore', {
	    interval: 3000,
	    storeid: 'ceph-pool-list' + nodename,
	    model: 'ceph-pool-list',
	    proxy: {
		type: 'proxmox',
		url: `/api2/json/nodes/${nodename}/ceph/pools`,
	    },
	});
	let store = Ext.create('Proxmox.data.DiffStore', { rstore: rstore });

	// manages the "install ceph?" overlay
	PVE.Utils.monitor_ceph_installed(me, rstore, nodename);

	var run_editor = function() {
	    let rec = sm.getSelection()[0];
	    if (!rec || !rec.data.pool_name) {
		return;
	    }
	    Ext.create('PVE.Ceph.PoolEdit', {
		title: gettext('Edit') + ': Ceph Pool',
		nodename: nodename,
		pool_name: rec.data.pool_name,
		autoShow: true,
		listeners: {
		    destroy: () => rstore.load(),
		},
	    });
	};

	Ext.apply(me, {
	    store: store,
	    selModel: sm,
	    tbar: [
		{
		    text: gettext('Create'),
		    handler: function() {
			Ext.create('PVE.Ceph.PoolEdit', {
			    title: gettext('Create') + ': Ceph Pool',
			    isCreate: true,
			    nodename: nodename,
			    autoShow: true,
			    listeners: {
				destroy: () => rstore.load(),
			    },
			});
		    },
		},
		{
		    xtype: 'proxmoxButton',
		    text: gettext('Edit'),
		    selModel: sm,
		    disabled: true,
		    handler: run_editor,
		},
		{
		    xtype: 'proxmoxButton',
		    text: gettext('Destroy'),
		    selModel: sm,
		    disabled: true,
		    handler: function() {
			let rec = sm.getSelection()[0];
			if (!rec || !rec.data.pool_name) {
			    return;
			}
			let poolName = rec.data.pool_name;
			Ext.create('Proxmox.window.SafeDestroy', {
			    showProgress: true,
			    url: `/nodes/${nodename}/ceph/pools/${poolName}`,
			    params: {
				remove_storages: 1,
			    },
			    item: {
				type: 'CephPool',
				id: poolName,
			    },
			    taskName: 'cephdestroypool',
			    autoShow: true,
			    listeners: {
				destroy: () => rstore.load(),
			    },
			});
		    },
		},
	    ],
	    listeners: {
		activate: () => rstore.startUpdate(),
		destroy: () => rstore.stopUpdate(),
		itemdblclick: run_editor,
	    },
	});

	me.callParent();
    },
}, function() {
    Ext.define('ceph-pool-list', {
	extend: 'Ext.data.Model',
	fields: ['pool_name',
		  { name: 'pool', type: 'integer' },
		  { name: 'size', type: 'integer' },
		  { name: 'min_size', type: 'integer' },
		  { name: 'pg_num', type: 'integer' },
		  { name: 'pg_num_min', type: 'integer' },
		  { name: 'bytes_used', type: 'integer' },
		  { name: 'percent_used', type: 'number' },
		  { name: 'crush_rule', type: 'integer' },
		  { name: 'crush_rule_name', type: 'string' },
		  { name: 'pg_autoscale_mode', type: 'string' },
		  { name: 'pg_num_final', type: 'integer' },
		  { name: 'target_size_ratio', type: 'number' },
		  { name: 'target_size', type: 'integer' },
		],
	idProperty: 'pool_name',
    });
});

Ext.define('PVE.form.CephRuleSelector', {
    extend: 'Ext.form.field.ComboBox',
    alias: 'widget.pveCephRuleSelector',

    allowBlank: false,
    valueField: 'name',
    displayField: 'name',
    editable: false,
    queryMode: 'local',

    initComponent: function() {
	let me = this;

	if (!me.nodename) {
	    throw "no nodename given";
	}
	Ext.apply(me, {
	    store: {
		fields: ['name'],
		sorters: 'name',
		proxy: {
		    type: 'proxmox',
		    url: `/api2/json/nodes/${me.nodename}/ceph/rules`,
		},
		autoLoad: me.isCreate ? {
		    callback: (records, op, success) => {
			if (success && records.length > 0) {
			    me.select(records[0]);
			}
		    },
		} : true,
	    },
	});

	me.callParent();
    },

});
