Ext.define('PVE.panel.TemplateStatusView',{
    extend: 'PVE.panel.StatusView',
    alias: 'widget.pveTemplateStatusView',

    layout: {
	type: 'vbox',
	align: 'stretch'
    },

    defaults: {
	xtype: 'pveInfoWidget',
	printBar: false,
	padding: '2 25'
    },
    items: [
	{
	    xtype: 'box',
	    height: 20
	},
	{
	    itemId: 'hamanaged',
	    iconCls: 'fa fa-heartbeat fa-fw',
	    title: gettext('HA State'),
	    printBar: false,
	    textField: 'ha',
	    renderer: PVE.Utils.format_ha
	},
	{
	    itemId: 'node',
	    iconCls: 'fa fa-fw fa-building',
	    title: gettext('Node')
	},
	{
	    xtype: 'box',
	    height: 20
	},
	{
	    itemId: 'cpus',
	    iconCls: 'fa fa-fw pve-itype-icon-processor pve-icon',
	    title: gettext('Processors'),
	    textField: 'cpus'
	},
	{
	    itemId: 'memory',
	    iconCls: 'fa fa-fw pve-itype-icon-memory pve-icon',
	    title: gettext('Memory'),
	    textField: 'maxmem',
	    renderer: PVE.Utils.render_size
	},
	{
	    itemId: 'swap',
	    iconCls: 'fa fa-refresh fa-fw',
	    title: gettext('Swap'),
	    textField: 'maxswap',
	    renderer: PVE.Utils.render_size
	},
	{
	    itemId: 'disk',
	    iconCls: 'fa fa-hdd-o fa-fw',
	    title: gettext('Bootdisk size'),
	    textField: 'maxdisk',
	    renderer: PVE.Utils.render_size
	},
	{
	    xtype: 'box',
	    height: 20
	}
    ],

    initComponent: function() {
	var me = this;

	var name = me.pveSelNode.data.name;
	if (!name) {
	    throw "no name specified";
	}

	me.title = name;

	me.callParent();
	if (me.pveSelNode.data.type !== 'lxc') {
	    me.remove(me.getComponent('swap'));
	}
	me.getComponent('node').updateValue(me.pveSelNode.data.node);
    }
});
