package PVE::API2::Ceph::MON;

use strict;
use warnings;

use Net::IP;
use File::Path;

use PVE::Ceph::Tools;
use PVE::Ceph::Services;
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network;
use PVE::RADOS;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools qw(run_command file_set_contents);
use PVE::CephConfig;
use PVE::API2::Ceph::MGR;

use base qw(PVE::RESTHandler);

my $find_mon_ip = sub {
    my ($cfg, $rados, $node, $overwrite_ip) = @_;

    my $pubnet;
    if ($rados) {
	$pubnet = $rados->mon_command({ prefix => "config get" , who => "mon.",
		key => "public_network", format => 'plain' });
	# if not defined in the db, the result is empty, it is also always
	# followed by a newline
	($pubnet) = $pubnet =~ m/^(\S+)$/;
    }
    $pubnet //= $cfg->{global}->{public_network};

    if (!$pubnet) {
	return $overwrite_ip // PVE::Cluster::remote_node_ip($node);
    }

    my $allowed_ips = PVE::Network::get_local_ip_from_cidr($pubnet);
    die "No active IP found for the requested ceph public network '$pubnet' on node '$node'\n"
	if scalar(@$allowed_ips) < 1;

    if (!$overwrite_ip) {
	if (scalar(@$allowed_ips) == 1 || !grep { $_ ne $allowed_ips->[0] } @$allowed_ips) {
	    return $allowed_ips->[0];
	}
	die "Multiple IPs for ceph public network '$pubnet' detected on $node:\n".
	    join("\n", @$allowed_ips) ."\nuse 'mon-address' to specify one of them.\n";
    } else {
	if (grep { $_ eq $overwrite_ip } @$allowed_ips) {
	    return $overwrite_ip;
	}
	die "Monitor IP '$overwrite_ip' not in ceph public network '$pubnet'\n"
	    if !PVE::Network::is_ip_in_cidr($overwrite_ip, $pubnet);

	die "Specified monitor IP '$overwrite_ip' not configured or up on $node!\n";
    }
};

my $assert_mon_prerequisites = sub {
    my ($cfg, $monhash, $monid, $monip) = @_;

    my $ip_regex = '(?:^|[^\d])' . # start or nondigit
	       "\Q$monip\E" .  # the ip not interpreted as regex
	       '(?:[^\d]|$)';  # end or nondigit

    if (($cfg->{global}->{mon_host} && $cfg->{global}->{mon_host} =~ m/$ip_regex/) ||
	grep { $_->{addr} && $_->{addr}  =~ m/$ip_regex/ } values %$monhash) {
	die "monitor address '$monip' already in use\n";
    }

    if (defined($monhash->{$monid})) {
	die "monitor '$monid' already exists\n";
    }
};

my $assert_mon_can_remove = sub {
    my ($monhash, $monlist, $monid, $mondir) = @_;

    if (!(defined($monhash->{"mon.$monid"}) ||
	  grep { $_->{name} && $_->{name} eq $monid } @$monlist))
    {
	die "no such monitor id '$monid'\n"
    }

    die "monitor filesystem '$mondir' does not exist on this node\n" if ! -d $mondir;
    die "can't remove last monitor\n" if scalar(@$monlist) <= 1;
};

__PACKAGE__->register_method ({
    name => 'listmon',
    path => '',
    method => 'GET',
    description => "Get Ceph monitor list.",
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
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		name => { type => 'string' },
		addr => { type => 'string', optional => 1 },
		host => { type => 'string', optional => 1 },
	    },
	},
	links => [ { rel => 'child', href => "{name}" } ],
    },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $res = [];

	my $cfg = cfs_read_file('ceph.conf');

	my $rados = eval { PVE::RADOS->new() };
	warn $@ if $@;
	my $monhash = PVE::Ceph::Services::get_services_info("mon", $cfg, $rados);

	if ($rados) {
	    my $monstat = $rados->mon_command({ prefix => 'quorum_status' });

	    my $mons = $monstat->{monmap}->{mons};
	    foreach my $d (@$mons) {
		next if !defined($d->{name});
		my $name = $d->{name};
		$monhash->{$name}->{rank} = $d->{rank};
		$monhash->{$name}->{addr} = $d->{addr};
		if (grep { $_ eq $d->{rank} } @{$monstat->{quorum}}) {
		    $monhash->{$name}->{quorum} = 1;
		    $monhash->{$name}->{state} = 'running';
		}
	    }

	} else {
	    # we cannot check the status if we do not have a RADOS
	    # object, so set the state to unknown
	    foreach my $monid (sort keys %$monhash) {
		$monhash->{$monid}->{state} = 'unknown';
	    }
	}

	return PVE::RESTHandler::hash_to_array($monhash, 'name');
    }});

__PACKAGE__->register_method ({
    name => 'createmon',
    path => '{monid}',
    method => 'POST',
    description => "Create Ceph Monitor and Manager",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    monid => {
		type => 'string',
		optional => 1,
		pattern => PVE::Ceph::Services::SERVICE_REGEX,
		maxLength => 200,
		description => "The ID for the monitor, when omitted the same as the nodename",
	    },
	    'mon-address' => {
		description => 'Overwrites autodetected monitor IP address. ' .
		               'Must be in the public network of ceph.',
		type => 'string', format => 'ip',
		optional => 1,
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_installed('ceph_mon');
	PVE::Ceph::Tools::check_ceph_inited();
	PVE::Ceph::Tools::setup_pve_symlinks();

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $cfg = cfs_read_file('ceph.conf');
	my $rados = eval { PVE::RADOS->new() }; # try a rados connection, fails for first monitor
	my $monhash = PVE::Ceph::Services::get_services_info('mon', $cfg, $rados);

	my $is_first_monitor = !(scalar(keys %$monhash) || $cfg->{global}->{mon_host});

	if (!defined($rados) && !$is_first_monitor) {
	    die "Could not connect to ceph cluster despite configured monitors\n";
	}

	my $monid = $param->{monid} // $param->{node};
	my $monsection = "mon.$monid";
	my $ip = $find_mon_ip->($cfg, $rados, $param->{node}, $param->{'mon-address'});

	$assert_mon_prerequisites->($cfg, $monhash, $monid, $ip);

	my $worker = sub  {
	    my $upid = shift;

	    PVE::Cluster::cfs_lock_file('ceph.conf', undef, sub {
		# update cfg content and reassert prereqs inside the lock
		$cfg = cfs_read_file('ceph.conf');
		# reopen with longer timeout
		if (defined($rados)) {
		    $rados = PVE::RADOS->new(timeout => PVE::Ceph::Tools::get_config('long_rados_timeout'));
		}
		$monhash = PVE::Ceph::Services::get_services_info('mon', $cfg, $rados);
		$assert_mon_prerequisites->($cfg, $monhash, $monid, $ip);

		my $client_keyring = PVE::Ceph::Tools::get_or_create_admin_keyring();
		my $mon_keyring = PVE::Ceph::Tools::get_config('pve_mon_key_path');

		if (! -f $mon_keyring) {
		    print "creating new monitor keyring\n";
		    run_command("ceph-authtool --create-keyring $mon_keyring ".
			" --gen-key -n mon. --cap mon 'allow *'");
		    run_command("ceph-authtool $mon_keyring --import-keyring $client_keyring");
		}

		my $ccname = PVE::Ceph::Tools::get_config('ccname');
		my $mondir =  "/var/lib/ceph/mon/$ccname-$monid";
		-d $mondir && die "monitor filesystem '$mondir' already exist\n";

		my $monmap = "/tmp/monmap";

		eval {
		    mkdir $mondir;

		    run_command("chown ceph:ceph $mondir");

		    if (defined($rados)) { # we can only have a RADOS object if we have a monitor
			my $mapdata = $rados->mon_command({ prefix => 'mon getmap', format => 'plain' });
			file_set_contents($monmap, $mapdata);
		    } else { # we need to create a monmap for the first monitor
			my $monaddr = $ip;
			if (Net::IP::ip_is_ipv6($ip)) {
			    $monaddr = "[$ip]";
			    $cfg->{global}->{ms_bind_ipv6} = 'true';
			    $cfg->{global}->{ms_bind_ipv4} = 'false';
			}
			run_command("monmaptool --create --clobber --addv $monid '[v2:$monaddr:3300,v1:$monaddr:6789]' --print $monmap");
		    }

		    run_command("ceph-mon --mkfs -i $monid --monmap $monmap --keyring $mon_keyring");
		    run_command("chown ceph:ceph -R $mondir");
		};
		my $err = $@;
		unlink $monmap;
		if ($err) {
		    File::Path::remove_tree($mondir);
		    die $err;
		}

		# update ceph.conf
		my $monhost = $cfg->{global}->{mon_host} // "";
		# add all known monitor ips to mon_host if it does not exist
		if (!defined($cfg->{global}->{mon_host})) {
		    for my $mon (sort keys %$monhash) {
			$monhost .= " " . $monhash->{$mon}->{addr};
		    }
		}
		$monhost .= " $ip";
		$cfg->{global}->{mon_host} = $monhost;
		# The IP is needed in the ceph.conf for the first boot
		$cfg->{$monsection}->{public_addr} = $ip;

		cfs_write_file('ceph.conf', $cfg);

		PVE::Ceph::Services::ceph_service_cmd('start', $monsection);

		if ($is_first_monitor) {
		    print "created the first monitor, assume it's safe to disable insecure global"
			." ID reclaim for new setup\n";
		    eval {
			run_command(
			    ['ceph', 'config', 'set', 'mon', 'auth_allow_insecure_global_id_reclaim', 'false'],
			    errfunc => sub { print STDERR "$_[0]\n" },
			)
		    };
		    warn "$@" if $@;
		}

		eval { PVE::Ceph::Services::ceph_service_cmd('enable', $monsection) };
		warn "Enable ceph-mon\@${monid}.service failed, do manually: $@\n" if $@;

		PVE::Ceph::Services::broadcast_ceph_services();
	    });
	    die $@ if $@;
	    # automatically create manager after the first monitor is created
	    if (scalar(keys %$monhash) <= 0) {

		PVE::API2::Ceph::MGR->createmgr({
		    node => $param->{node},
		    id => $param->{node}
		})
	    }
	};

	return $rpcenv->fork_worker('cephcreatemon', $monsection, $authuser, $worker);
    }});

__PACKAGE__->register_method ({
    name => 'destroymon',
    path => '{monid}',
    method => 'DELETE',
    description => "Destroy Ceph Monitor and Manager.",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    monid => {
		description => 'Monitor ID',
		type => 'string',
		pattern => PVE::Ceph::Services::SERVICE_REGEX,
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	PVE::Ceph::Tools::check_ceph_inited();

	my $cfg = cfs_read_file('ceph.conf');

	my $monid = $param->{monid};
	my $monsection = "mon.$monid";

	my $rados = PVE::RADOS->new();
	my $monstat = $rados->mon_command({ prefix => 'quorum_status' });
	my $monlist = $monstat->{monmap}->{mons};
	my $monhash = PVE::Ceph::Services::get_services_info('mon', $cfg, $rados);

	my $ccname = PVE::Ceph::Tools::get_config('ccname');
	my $mondir =  "/var/lib/ceph/mon/$ccname-$monid";

	$assert_mon_can_remove->($monhash, $monlist, $monid, $mondir);

	my $worker = sub {
	    my $upid = shift;
	    PVE::Cluster::cfs_lock_file('ceph.conf', undef, sub {
		# reload info and recheck
		$cfg = cfs_read_file('ceph.conf');

		# reopen with longer timeout
		$rados = PVE::RADOS->new(timeout => PVE::Ceph::Tools::get_config('long_rados_timeout'));
		$monhash = PVE::Ceph::Services::get_services_info('mon', $cfg, $rados);
		$monstat = $rados->mon_command({ prefix => 'quorum_status' });
		$monlist = $monstat->{monmap}->{mons};

		my $addr;
		for my $mon (@$monlist) {
		    if ($mon->{name} eq $monid) {
			$addr = $mon->{public_addr} // $mon->{addr};
			($addr) = $addr =~ m|^(.*):\d+/\d+$|; # extract the ip without port/nonce
			last;
		    }
		}

		$assert_mon_can_remove->($monhash, $monlist, $monid, $mondir);

		# this also stops the service
		$rados->mon_command({ prefix => "mon remove", name => $monid, format => 'plain' });

		# delete section
		delete $cfg->{$monsection};

		# delete from mon_host
		if (my $monhost = $cfg->{global}->{mon_host}) {
		    # various replaces to remove the ip
		    # we always match the beginning or a separator (also at the end)
		    # so we do not accidentally remove a wrong ip
		    # e.g. removing 10.0.0.1 should not remove 10.0.0.101 or 110.0.0.1

		    # remove vector containing this ip
		    # format is [vX:ip:port/nonce,vY:ip:port/nonce]
		    my $vectorpart_re = "v\\d+:\Q$addr\E:\\d+\\/\\d+";
		    $monhost =~ s/(^|[ ,;]*)\[$vectorpart_re(?:,$vectorpart_re)*\](?:[ ,;]+|$)/$1/;

		    # ip (+ port)
		    $monhost =~ s/(^|[ ,;]+)\Q$addr\E(?::\d+)?(?:[ ,;]+|$)/$1/;

		    # ipv6 only without brackets
		    if ($addr =~ m/^\[?(.*?:.*?)\]?$/) {
			$addr = $1;
			$monhost =~ s/(^|[ ,;]+)\Q$addr\E(?:[ ,;]+|$)/$1/;
		    }

		    # remove trailing separators
		    $monhost =~ s/[ ,;]+$//;

		    $cfg->{global}->{mon_host} = $monhost;
		}

		cfs_write_file('ceph.conf', $cfg);
		File::Path::remove_tree($mondir);
		eval { PVE::Ceph::Services::ceph_service_cmd('disable', $monsection) };
		warn $@ if $@;
		PVE::Ceph::Services::broadcast_ceph_services();
	    });

	    die $@ if $@;
	};

	return $rpcenv->fork_worker('cephdestroymon', $monsection,  $authuser, $worker);
    }});

1;
