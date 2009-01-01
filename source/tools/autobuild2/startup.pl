=pod

This script is executed on startup (via a service) on the build server.

It is responsible for:
 * attaching the necessary disks,
 * updating from SVN,
 * executing the rest of the build script that's in SVN,
 * cleaning up at the end,
 * and saving the logs of everything that's going on.

This script does as little as possible, since it is necessarily frozen
into the static machine image and is hard to update.

=cut

use strict;
use warnings;

use Net::Amazon::EC2;
use Amazon::S3;
use LWP::Simple();
use DateTime;

my %config = load_conf("c:\\0ad\\autobuild\\aws.conf");
my $timestamp = DateTime->now->iso8601;

my $s3 = new Amazon::S3( {
    aws_access_key_id => $config{aws_access_key_id},
    aws_secret_access_key => $config{aws_secret_access_key},
    retry => 1,
} );


my $bucket = $s3->bucket('wfg-autobuild-logs');

my $log = '';

$SIG{__WARN__} = sub {
    write_log("Warning: @_");
    warn @_;
};

write_log("Starting");
flush_log();

my $ec2;

$SIG{__DIE__} = sub {
    die @_ if $^S; # ignore deaths in eval

    write_log("Died\n@_");
    flush_log();
    if ($ec2) {
        terminate_instance();
    }
    die @_;
};

$ec2 = new Net::Amazon::EC2(
    AWSAccessKeyId => $config{aws_access_key_id},
    SecretAccessKey => $config{aws_secret_access_key},
);

my $instance_id = get_instance_id();
write_log("Running on instance $instance_id");
flush_log();

attach_disk();

update_svn();

run_build_script();

save_buildlogs();

detach_disk();

write_log("Finished");

terminate_instance();

exit;

sub update_svn {
    write_log("Updating from SVN");
    my $output = `svn up --username $config{svn_username} --password $config{svn_password} e:\\svn 2>&1`;
    write_log("svn up:\n================================\n$output\n================================\n");
}

sub run_build_script {
    write_log("Running build script");
    system("perl e:\\svn\\source\\tools\\autobuild2\\build.pl");
}

sub save_buildlogs {
    opendir my $d, "d:\\0ad\\buildlogs" or die "Can't open buildlogs directory: $!";
    for my $fn (sort readdir $d) {
        next if $fn =~ /^\./;
        open my $f, '<', "d:\\0ad\\buildlogs\\$fn" or die "Can't open buildlogs file $fn: $!";
        my $data = do { local $/; <$f> };
        write_log("$fn:\n================================\n$data\n================================\n");
    }
}

sub attach_disk {
    write_log("Attaching volume $config{ebs_volume_id} as $config{ebs_device}");
    my $status = $ec2->attach_volume(
        InstanceId => $instance_id,
        VolumeId => $config{ebs_volume_id},
        Device => $config{ebs_device},
    );
    write_log("Attached");

    # Wait for the disk to get attached and visible
    write_log("Waiting for volume to be visible");
    my $mounts;
    for my $i (0..60) {
        # mountvol emits a list of volumes, so wait until the expected one is visible
        $mounts = `mountvol`;
        my $letter = uc $config{ebs_drive_letter};
        if ($mounts =~ /(\\\\\?\\Volume\{\S+\}\\)\s+$letter:\\/) {
            my $volume = $1;
            write_log("Already got volume $volume mounted on drive $config{ebs_drive_letter}");
            return;
        } elsif ($mounts =~ /(\\\\\?\\Volume\{\S+\}\\)\s+\*\*\* NO MOUNT POINTS \*\*\*/) {
            my $volume = $1;
            write_log("Mounting volume $volume onto drive $config{ebs_drive_letter}");
            system("mountvol $config{ebs_drive_letter}: $volume");
            return;
        }
        write_log("Not seen the volume yet ($i)");
        sleep 1;
    }

    die "Failed to find new volume. mountvol said:\n\n$mounts";
}

sub detach_disk {
    # Based on http://developer.amazonwebservices.com/connect/entry.jspa?externalID=1841&categoryID=174
    write_log("Syncing drive $config{ebs_drive_letter}");
    system("$config{sync} -r $config{ebs_drive_letter}:");

    write_log("Unmounting drive $config{ebs_drive_letter}");
    system("mountvol $config{ebs_drive_letter}: /d");

    write_log("Detaching volume");
    my $status = $ec2->detach_volume(
        InstanceId => $instance_id,
        VolumeId => $config{ebs_volume_id},
    );
    write_log("Detached");
}

sub terminate_instance {
    write_log("Terminating instance (after a delay)");
    flush_log();

#     write_log("NOT REALLY");
#     flush_log();
#     return;

    # Delay for a while, to give me a chance to log in and manually
    # abort the termination if I want to configure the machine instead
    # of having it die straightaway
    sleep 60*5;
    write_log("Really terminating now");
    flush_log();
    my $statuses = $ec2->terminate_instances(
        InstanceId => $instance_id,
    );
    write_log("Terminated");
    flush_log();
}

sub get_instance_id {
    my $instance_id = LWP::Simple::get("$config{ec2_metadata_root}instance-id");
    die "Invalid instance-id return value '$instance_id'" unless $instance_id =~ /\Ai-[a-f0-9]+\z/;
    return $instance_id;
}

sub write_log {
    my ($msg) = @_;

    print "$msg\n";
    my $t = scalar gmtime;
    $log .= "$t: $msg\n\n";

    # Instead of using the explicit flush_log, just flush all
    # the time because it helps with debugging
    flush_log_really();
}

sub flush_log_really {
    my $filename = "$timestamp.startup";

    my $ok = $bucket->add_key($filename, $log, {
        acl_short => 'public-read',
        'Content-Type' => 'text/plain',
    });
    warn "Failed - ".$bucket->errstr if not $ok;
}

sub flush_log {
#     flush_log_really();
}


sub load_conf {
    my ($filename) = @_;
    open my $f, '<', $filename or die "Failed to open $filename: $!";
    my %c;
    while (<$f>) {
        if (/^(.+?): (.+)/) {
            $c{$1} = $2;
        }
    }
    return %c;
}
