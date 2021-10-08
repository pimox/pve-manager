package PVE::API2::Ceph::OSD;

use strict;
use warnings;

use Cwd qw(abs_path);
use IO::File;
use UUID;

use PVE::Ceph::Tools;
use PVE::Ceph::Services;
use PVE::CephConfig;
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Diskmanage;
use PVE::Storage::LVMPlugin;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;
use PVE::RADOS;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools qw(run_command file_set_contents);
use PVE::ProcFSTools;
use PVE::Network;

use base qw(PVE::RESTHandler);

my $nodename = PVE::INotify::nodename();

my $get_osd_status = sub {
    my ($rados, $osdid) = @_;

    my $stat = $rados->mon_command({ prefix => 'osd dump' });

    my $osdlist = $stat->{osds} || [];

    my $flags = $stat->{flags} || undef;

    my $osdstat;
    foreach my $d (@$osdlist) {
	$osdstat->{$d->{osd}} = $d if defined($d->{osd});
    }
    if (defined($osdid)) {
	die "no such OSD '$osdid'\n" if !$osdstat->{$osdid};
	return $osdstat->{$osdid};
    }

    return wantarray ? ($osdstat, $flags) : $osdstat;
};

my $get_osd_usage = sub {
    my ($rados) = @_;

    my $osdlist = $rados->mon_command({ prefix => 'pg dump', dumpcontents => [ 'osds' ]});
    if (!($osdlist && ref($osdlist))) {
	warn "got unknown result format for 'pg dump osds' command\n";
	return [];
    }

    if (ref($osdlist) eq "HASH") { # since nautilus
	$osdlist = $osdlist->{osd_stats};
    }

    my $osdstat = {};
    for my $d (@$osdlist) {
	$osdstat->{$d->{osd}} = $d if defined($d->{osd});
    }

    return $osdstat;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Get Ceph osd list/tree.",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit', 'Datastore.Audit' ], any => 1],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    # fixme: return a list instead of extjs tree format ?
    returns => {
	type => "object",
    },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $rados = PVE::RADOS->new();
	my $res = $rados->mon_command({ prefix => 'osd tree' });

        die "no tree nodes found\n" if !($res && $res->{nodes});

	my ($osdhash, $flags) = $get_osd_status->($rados);

	my $osd_usage = $get_osd_usage->($rados);

	my $osdmetadata_res = $rados->mon_command({ prefix => 'osd metadata' });
	my $osdmetadata = { map { $_->{id} => $_ } @$osdmetadata_res };

	my $hostversions = PVE::Cluster::get_node_kv("ceph-version");

	my $nodes = {};
	my $newnodes = {};
	foreach my $e (@{$res->{nodes}}) {
	    my ($id, $name) = $e->@{qw(id name)};

	    $nodes->{$id} = $e;

	    my $new = {
		id => $id,
		name => $name,
		type => $e->{type}
	    };

	    foreach my $opt (qw(status crush_weight reweight device_class)) {
		$new->{$opt} = $e->{$opt} if defined($e->{$opt});
	    }

	    if (my $stat = $osdhash->{$id}) {
		$new->{in} = $stat->{in} if defined($stat->{in});
	    }

	    if (my $stat = $osd_usage->{$id}) {
		$new->{total_space} = ($stat->{kb} || 1) * 1024;
		$new->{bytes_used} = ($stat->{kb_used} || 0) * 1024;
		$new->{percent_used} = ($new->{bytes_used}*100)/$new->{total_space};
		if (my $d = $stat->{perf_stat}) {
		    $new->{commit_latency_ms} = $d->{commit_latency_ms};
		    $new->{apply_latency_ms} = $d->{apply_latency_ms};
		}
	    }

	    my $osdmd = $osdmetadata->{$id};
	    if ($e->{type} eq 'osd' && $osdmd) {
		if ($osdmd->{bluefs}) {
		    $new->{osdtype} = 'bluestore';
		    $new->{blfsdev} = $osdmd->{bluestore_bdev_dev_node};
		    $new->{dbdev} = $osdmd->{bluefs_db_dev_node};
		    $new->{waldev} = $osdmd->{bluefs_wal_dev_node};
		} else {
		    $new->{osdtype} = 'filestore';
		}
		for my $field (qw(ceph_version ceph_version_short)) {
		    $new->{$field} = $osdmd->{$field} if $osdmd->{$field};
		}
	    }

	    $newnodes->{$id} = $new;
	}

	foreach my $e (@{$res->{nodes}}) {
	    my ($id, $name) = $e->@{qw(id name)};
	    my $new = $newnodes->{$id};

	    if ($e->{children} && scalar(@{$e->{children}})) {
		$new->{children} = [];
		$new->{leaf} = 0;
		foreach my $cid (@{$e->{children}}) {
		    $nodes->{$cid}->{parent} = $id;
		    if ($nodes->{$cid}->{type} eq 'osd' && $e->{type} eq 'host') {
			$newnodes->{$cid}->{host} = $name;
		    }
		    push @{$new->{children}}, $newnodes->{$cid};
		}
	    } else {
		$new->{leaf} = ($id >= 0) ? 1 : 0;
	    }

	    if ($name && $e->{type} eq 'host') {
		$new->{version} = $hostversions->{$name};
	    }
	}

	my $realroots = [];
	foreach my $e (@{$res->{nodes}}) {
	    my $id = $e->{id};
	    if (!$nodes->{$id}->{parent}) {
		push @$realroots, $newnodes->{$id};
	    }
	}

	die "no root node\n" if scalar(@$realroots) < 1;

	my $data = {
	    root => {
		leaf =>  0,
		children => $realroots
	    },
	    versions => $hostversions, # for compatibility
	};

	$data->{flags} = $flags if $flags; # we want this for the noout flag

	return $data;
    }});

__PACKAGE__->register_method ({
    name => 'createosd',
    path => '',
    method => 'POST',
    description => "Create OSD",
    proxyto => 'node',
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    dev => {
		description => "Block device name.",
		type => 'string',
	    },
	    db_dev => {
		description => "Block device name for block.db.",
		optional => 1,
		type => 'string',
	    },
	    db_dev_size => {
		description => "Size in GiB for block.db.",
		verbose_description => "If a block.db is requested but the size is not given, ".
		    "will be automatically selected by: bluestore_block_db_size from the ".
		    "ceph database (osd or global section) or config (osd or global section)".
		    "in that order. If this is not available, it will be sized 10% of the size ".
		    "of the OSD device. Fails if the available size is not enough.",
		optional => 1,
		type => 'number',
		default => 'bluestore_block_db_size or 10% of OSD size',
		requires => 'db_dev',
		minimum => 1.0,
	    },
	    wal_dev => {
		description => "Block device name for block.wal.",
		optional => 1,
		type => 'string',
	    },
	    wal_dev_size => {
		description => "Size in GiB for block.wal.",
		verbose_description => "If a block.wal is requested but the size is not given, ".
		    "will be automatically selected by: bluestore_block_wal_size from the ".
		    "ceph database (osd or global section) or config (osd or global section)".
		    "in that order. If this is not available, it will be sized 1% of the size ".
		    "of the OSD device. Fails if the available size is not enough.",
		optional => 1,
		minimum => 0.5,
		default => 'bluestore_block_wal_size or 1% of OSD size',
		requires => 'wal_dev',
		type => 'number',
	    },
	    encrypted => {
		type => 'boolean',
		optional => 1,
		default => 0,
		description => "Enables encryption of the OSD."
	    },
	    'crush-device-class' => {
		optional => 1,
		type => 'string',
		description => "Set the device class of the OSD in crush."
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	# test basic requirements
	PVE::Ceph::Tools::check_ceph_inited();
	PVE::Ceph::Tools::setup_pve_symlinks();
	PVE::Ceph::Tools::check_ceph_installed('ceph_osd');
	PVE::Ceph::Tools::check_ceph_installed('ceph_volume');

	# extract parameter info and fail if a device is set more than once
	my $devs = {};

	my $ceph_conf = cfs_read_file('ceph.conf');

	my $osd_network = $ceph_conf->{global}->{cluster_network};
	$osd_network //= $ceph_conf->{global}->{public_network}; # fallback

	if ($osd_network) { # check only if something is configured
	    my $cluster_net_ips = PVE::Network::get_local_ip_from_cidr($osd_network);
	    if (scalar(@$cluster_net_ips) < 1) {
		my $osd_net_obj = PVE::Network::IP_from_cidr($osd_network);
		my $osd_base_cidr = $osd_net_obj->{ip} . "/" . $osd_net_obj->{prefixlen};

		die "No address from ceph cluster network (${osd_base_cidr}) found on node '$nodename'. ".
		    "Check your network config.\n";
	    }
	}

	for my $type ( qw(dev db_dev wal_dev) ) {
	    next if !$param->{$type};

	    my $type_dev = PVE::Diskmanage::verify_blockdev_path($param->{$type});
	    (my $type_devname = $type_dev) =~ s|/dev/||;

	    raise_param_exc({ $type => "cannot chose '$type_dev' for more than one type." })
		if grep { $_->{name} eq $type_devname } values %$devs;

	    $devs->{$type} = {
		dev => $type_dev,
		name => $type_devname,
	    };

	    if (my $size = $param->{"${type}_size"}) {
		$devs->{$type}->{size} = PVE::Tools::convert_size($size, 'gb' => 'b') ;
	    }
	}

	my $test_disk_requirements = sub {
	    my ($disklist) = @_;

	    my $dev = $devs->{dev}->{dev};
	    my $devname = $devs->{dev}->{name};
	    die "unable to get device info for '$dev'\n" if !$disklist->{$devname};
	    die "device '$dev' is already in use\n" if $disklist->{$devname}->{used};

	    for my $type ( qw(db_dev wal_dev) ) {
		my $d = $devs->{$type};
		next if !$d;
		my $name = $d->{name};
		my $info = $disklist->{$name};
		die "unable to get device info for '$d->{dev}' for type $type\n" if !$disklist->{$name};
		if (my $usage = $info->{used}) {
		    if ($usage eq 'partitions') {
			die "device '$d->{dev}' is not GPT partitioned\n" if !$info->{gpt};
		    } elsif ($usage ne 'LVM') {
			die "device '$d->{dev}' is already in use and has no LVM on it\n";
		    }
		}
	    }
	};


	# test disk requirements early
	my $devlist = [ map { $_->{name} } values %$devs ];
	my $disklist = PVE::Diskmanage::get_disks($devlist, 1);
	$test_disk_requirements->($disklist);

	# get necessary ceph infos
	my $rados = PVE::RADOS->new();
	my $monstat = $rados->mon_command({ prefix => 'quorum_status' });

	die "unable to get fsid\n" if !$monstat->{monmap} || !$monstat->{monmap}->{fsid};
	my $fsid = $monstat->{monmap}->{fsid};
        $fsid = $1 if $fsid =~ m/^([0-9a-f\-]+)$/;

	my $ceph_bootstrap_osd_keyring = PVE::Ceph::Tools::get_config('ceph_bootstrap_osd_keyring');

	if (! -f $ceph_bootstrap_osd_keyring && $ceph_conf->{global}->{auth_client_required} eq 'cephx') {
	    my $bindata = $rados->mon_command({
		    prefix => 'auth get-or-create',
		    entity => 'client.bootstrap-osd',
		    caps => [
			'mon' => 'allow profile bootstrap-osd'
		    ],
		    format => 'plain',
		});
	    file_set_contents($ceph_bootstrap_osd_keyring, $bindata);
	};

	# See FIXME below
	my @udev_trigger_devs = ();

	my $create_part_or_lv = sub {
	    my ($dev, $size, $type) = @_;

	    $size =~ m/^(\d+)$/ or die "invalid size '$size'\n";
	    $size = $1;

	    die "'$dev->{devpath}' is smaller than requested size '$size' bytes\n"
		if $dev->{size} < $size;

	    # sgdisk and lvcreate can only sizes divisible by 512b
	    # so we round down to the nearest kb
	    $size = PVE::Tools::convert_size($size, 'b' => 'kb', 1);

	    if (!$dev->{used}) {
		# create pv,vg,lv

		my $vg = "ceph-" . UUID::uuid();
		my $lv = $type . "-" . UUID::uuid();

		PVE::Storage::LVMPlugin::lvm_create_volume_group($dev->{devpath}, $vg);
		PVE::Storage::LVMPlugin::lvcreate($vg, $lv, "${size}k");

		push @udev_trigger_devs, $dev->{devpath};

		return "$vg/$lv";

	    } elsif ($dev->{used} eq 'LVM') {
		# check pv/vg and create lv

		my $vgs = PVE::Storage::LVMPlugin::lvm_vgs(1);
		my $vg;
		for my $vgname ( sort keys %$vgs ) {
		    next if $vgname !~ /^ceph-/;

		    for my $pv ( @{$vgs->{$vgname}->{pvs}} ) {
			next if $pv->{name} ne $dev->{devpath};
			$vg = $vgname;
			last;
		    }
		    last if $vg;
		}

		die "no ceph vg found on '$dev->{devpath}'\n" if !$vg;
		die "vg '$vg' has not enough free space\n" if $vgs->{$vg}->{free} < $size;

		my $lv = $type . "-" . UUID::uuid();

		PVE::Storage::LVMPlugin::lvcreate($vg, $lv, "${size}k");

		return "$vg/$lv";

	    } elsif ($dev->{used} eq 'partitions' && $dev->{gpt}) {
		# create new partition at the end

		my $part = PVE::Diskmanage::append_partition($dev->{devpath}, $size * 1024);
		push @udev_trigger_devs, $part;
		return $part;
	    }

	    die "cannot use '$dev->{devpath}' for '$type'\n";
	};

	my $worker = sub {
	    my $upid = shift;

	    PVE::Diskmanage::locked_disk_action(sub {
		# update disklist and re-test requirements
		$disklist = PVE::Diskmanage::get_disks($devlist, 1);
		$test_disk_requirements->($disklist);

		my $dev_class = $param->{'crush-device-class'};
		my $cmd = ['ceph-volume', 'lvm', 'create', '--cluster-fsid', $fsid ];
		push @$cmd, '--crush-device-class', $dev_class if $dev_class;

		my $devname = $devs->{dev}->{name};
		my $devpath = $disklist->{$devname}->{devpath};
		print "create OSD on $devpath (bluestore)\n";

		push @udev_trigger_devs, $devpath;

		my $osd_size = $disklist->{$devname}->{size};
		my $size_map = {
		    db => int($osd_size / 10), # 10% of OSD
		    wal => int($osd_size / 100), # 1% of OSD
		};

		my $sizes;
		foreach my $type ( qw(db wal) ) {
		    my $fallback_size = $size_map->{$type};
		    my $d = $devs->{"${type}_dev"};
		    next if !$d;

		    # size was not set via api, getting from config/fallback
		    if (!defined($d->{size})) {
			$sizes = PVE::Ceph::Tools::get_db_wal_sizes() if !$sizes;
			$d->{size} = $sizes->{$type} // $fallback_size;
		    }
		    print "creating block.$type on '$d->{dev}'\n";
		    my $name = $d->{name};
		    my $part_or_lv = $create_part_or_lv->($disklist->{$name}, $d->{size}, "osd-$type");

		    print "using '$part_or_lv' for block.$type\n";
		    push @$cmd, "--block.$type", $part_or_lv;
		}

		push @$cmd, '--data', $devpath;
		push @$cmd, '--dmcrypt' if $param->{encrypted};

		PVE::Diskmanage::wipe_blockdev($devpath);

		run_command($cmd);

		# FIXME: Remove once we depend on systemd >= v249.
		# Work around udev bug https://github.com/systemd/systemd/issues/18525 to ensure the
		# udev database is updated.
		eval { run_command(['udevadm', 'trigger', @udev_trigger_devs]); };
		warn $@ if $@;
	    });
	};

	return $rpcenv->fork_worker('cephcreateosd', $devs->{dev}->{name},  $authuser, $worker);
    }});

# Check if $osdid belongs to $nodename
# $tree ... rados osd tree (passing the tree makes it easy to test)
sub osd_belongs_to_node {
    my ($tree, $nodename, $osdid) = @_;
    return 0 if !($tree && $tree->{nodes});

    my $node_map = {};
    for my $el (grep { defined($_->{type}) && $_->{type} eq 'host' } @{$tree->{nodes}}) {
	my $name = $el->{name};
	die "internal error: duplicate host name found '$name'\n" if $node_map->{$name};
	$node_map->{$name} = $el;
    }

    my $osds = $node_map->{$nodename}->{children};
    return 0 if !$osds;

    return grep($_ == $osdid, @$osds);
}

__PACKAGE__->register_method ({
    name => 'destroyosd',
    path => '{osdid}',
    method => 'DELETE',
    description => "Destroy OSD",
    proxyto => 'node',
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    osdid => {
		description => 'OSD ID',
		type => 'integer',
	    },
	    cleanup => {
		description => "If set, we remove partition table entries.",
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	PVE::Ceph::Tools::check_ceph_inited();

	my $osdid = $param->{osdid};
	my $cleanup = $param->{cleanup};

	my $rados = PVE::RADOS->new();

	my $osd_belongs_to_node = osd_belongs_to_node(
	    $rados->mon_command({ prefix => 'osd tree' }),
	    $param->{node},
	    $osdid,
	);
	die "OSD osd.$osdid does not belong to node $param->{node}!"
	    if !$osd_belongs_to_node;

	# dies if osdid is unknown
	my $osdstat = $get_osd_status->($rados, $osdid);

	die "osd is in use (in == 1)\n" if $osdstat->{in};
	#&$run_ceph_cmd(['osd', 'out', $osdid]);

	die "osd is still running (up == 1)\n" if $osdstat->{up};

	my $osdsection = "osd.$osdid";

	my $worker = sub {
	    my $upid = shift;

	    # reopen with longer timeout
	    $rados = PVE::RADOS->new(timeout => PVE::Ceph::Tools::get_config('long_rados_timeout'));

	    print "destroy OSD $osdsection\n";

	    eval {
		PVE::Ceph::Services::ceph_service_cmd('stop', $osdsection);
		PVE::Ceph::Services::ceph_service_cmd('disable', $osdsection);
	    };
	    warn $@ if $@;

	    print "Remove $osdsection from the CRUSH map\n";
	    $rados->mon_command({ prefix => "osd crush remove", name => $osdsection, format => 'plain' });

	    print "Remove the $osdsection authentication key.\n";
	    $rados->mon_command({ prefix => "auth del", entity => $osdsection, format => 'plain' });

	    print "Remove OSD $osdsection\n";
	    $rados->mon_command({ prefix => "osd rm", ids => [ $osdsection ], format => 'plain' });

	    # try to unmount from standard mount point
	    my $mountpoint = "/var/lib/ceph/osd/ceph-$osdid";

	    # See FIXME below
	    my $udev_trigger_devs = {};

	    my $remove_partition = sub {
		my ($part) = @_;

		return if !$part || (! -b $part );
		my $partnum = PVE::Diskmanage::get_partnum($part);
		my $devpath = PVE::Diskmanage::get_blockdev($part);

		$udev_trigger_devs->{$devpath} = 1;

		PVE::Diskmanage::wipe_blockdev($part);
		print "remove partition $part (disk '${devpath}', partnum $partnum)\n";
		eval { run_command(['/sbin/sgdisk', '-d', $partnum, "${devpath}"]); };
		warn $@ if $@;
	    };

	    my $osd_list = PVE::Ceph::Tools::ceph_volume_list();

	    if ($osd_list->{$osdid}) { # ceph-volume managed

		eval { PVE::Ceph::Tools::ceph_volume_zap($osdid, $cleanup) };
		warn $@ if $@;

		if ($cleanup) {
		    # try to remove pvs, but do not fail if it does not work
		    for my $osd_part (@{$osd_list->{$osdid}}) {
			for my $dev (@{$osd_part->{devices}}) {
			    ($dev) = ($dev =~ m|^(/dev/[-_.a-zA-Z0-9\/]+)$|); #untaint

			    eval { run_command(['/sbin/pvremove', $dev], errfunc => sub {}) };
			    warn $@ if $@;

			    $udev_trigger_devs->{$dev} = 1;
			}
		    }
		}
	    } else {
		my $partitions_to_remove = [];
		if ($cleanup) {
		    if (my $mp = PVE::ProcFSTools::parse_proc_mounts()) {
			foreach my $line (@$mp) {
			    my ($dev, $path, $fstype) = @$line;
			    next if !($dev && $path && $fstype);
			    next if $dev !~ m|^/dev/|;

			    if ($path eq $mountpoint) {
				abs_path($dev) =~ m|^(/.+)| or die "invalid dev: $dev\n";
				push @$partitions_to_remove, $1;
				last;
			    }
			}
		    }

		    foreach my $path (qw(journal block block.db block.wal)) {
			abs_path("$mountpoint/$path") =~ m|^(/.+)| or die "invalid path: $path\n";
			push @$partitions_to_remove, $1;
		    }
		}

		print "Unmount OSD $osdsection from  $mountpoint\n";
		eval { run_command(['/bin/umount', $mountpoint]); };
		if (my $err = $@) {
		    warn $err;
		} elsif ($cleanup) {
		    #be aware of the ceph udev rules which can remount.
		    foreach my $part (@$partitions_to_remove) {
			$remove_partition->($part);
		    }
		}
	    }

	    # FIXME: Remove once we depend on systemd >= v249.
	    # Work around udev bug https://github.com/systemd/systemd/issues/18525 to ensure the
	    # udev database is updated.
	    if ($cleanup) {
		eval { run_command(['udevadm', 'trigger', keys $udev_trigger_devs->%*]); };
		warn $@ if $@;
	    }
	};

	return $rpcenv->fork_worker('cephdestroyosd', $osdsection,  $authuser, $worker);
    }});

__PACKAGE__->register_method ({
    name => 'in',
    path => '{osdid}/in',
    method => 'POST',
    description => "ceph osd in",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    osdid => {
		description => 'OSD ID',
		type => 'integer',
	    },
	},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $osdid = $param->{osdid};

	my $rados = PVE::RADOS->new();

	$get_osd_status->($rados, $osdid); # osd exists?

	my $osdsection = "osd.$osdid";

	$rados->mon_command({ prefix => "osd in", ids => [ $osdsection ], format => 'plain' });

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'out',
    path => '{osdid}/out',
    method => 'POST',
    description => "ceph osd out",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    osdid => {
		description => 'OSD ID',
		type => 'integer',
	    },
	},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $osdid = $param->{osdid};

	my $rados = PVE::RADOS->new();

	$get_osd_status->($rados, $osdid); # osd exists?

	my $osdsection = "osd.$osdid";

	$rados->mon_command({ prefix => "osd out", ids => [ $osdsection ], format => 'plain' });

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'scrub',
    path => '{osdid}/scrub',
    method => 'POST',
    description => "Instruct the OSD to scrub.",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    osdid => {
		description => 'OSD ID',
		type => 'integer',
	    },
	    deep => {
		description => 'If set, instructs a deep scrub instead of a normal one.',
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $osdid = $param->{osdid};
	my $deep = $param->{deep} // 0;

	my $rados = PVE::RADOS->new();

	$get_osd_status->($rados, $osdid); # osd exists?

	my $prefix = $deep ? 'osd deep-scrub' : 'osd scrub';
	$rados->mon_command({ prefix => $prefix, who => $osdid });

	return undef;
    }});

1;
