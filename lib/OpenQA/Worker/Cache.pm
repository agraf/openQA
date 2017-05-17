# Copyright (C) 2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Worker::Cache;
use strict;
use warnings;

use File::Basename;
use Fcntl ':flock';
use Mojo::UserAgent;
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::Worker::Common;
use List::MoreUtils;
use File::Spec::Functions 'catdir';
use File::Path qw(remove_tree make_path);
use Data::Dumper;
use JSON;
use DBI;


require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(get_asset);

my $cache;
my $host;
my $location;
our $limit = 50 * 1024 * 1024 * 1024;
my $db_file;
my $dsn;
my $dbh;
my $cache_real_size;

END {
    $dbh->disconnect() if $dbh;
}

sub deploy_cache {
    local $/;
    my $sql = <DATA>;
    log_info "Creating cache directory tree for $location";
    remove_tree($location, {keep_root => 1});
    make_path(File::Spec->catdir($location, Mojo::URL->new($host)->host));
    make_path(File::Spec->catdir($location, 'tmp'));

    log_info "Deploying DB: $sql";
    $dbh = DBI->connect($dsn, undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 0})
      or die("Could not connect to the dbfile.");
    $dbh->do($sql);
    $dbh->commit;
    $dbh->disconnect;
}

sub init {
    ($host, $location) = @_;
    $db_file = catdir($location, 'cache.sqlite');
    $dsn = "dbi:SQLite:dbname=$db_file";
    deploy_cache unless (-e $db_file);
    $dbh = DBI->connect($dsn, undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 1})
      or die("Could not connect to the dbfile.");
    $cache_real_size = 0;
    cache_cleanup();
    #Ideally we only need $limit, and $need no extra space
    check_limits(0);
    log_info(__PACKAGE__ . ": Initialized with $host at $location, current size is $cache_real_size");
}

sub download_asset {
    my ($id, $type, $asset, $etag) = @_;

    open(my $log, '>>', "autoinst-log.txt") or die("Cannot open autoinst-log.txt");
    local $| = 1;
    my $ua = Mojo::UserAgent->new(max_redirects => 2);
    $ua->max_response_size(0);
    my $url = sprintf '%s/tests/%d/asset/%s/%s', $host, $id, $type, basename($asset);
    print $log "Downloading " . basename($asset) . " from $url\n";
    my $tx = $ua->build_tx(GET => $url);
    my $headers;

    $ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            my $progress     = 0;
            my $last_updated = time;
            $tx->req->headers->header('If-None-Match' => qq{$etag}) if $etag;
            $tx->res->on(
                progress => sub {
                    my $msg = shift;
                    $msg->finish if $msg->code == 304;
                    return unless my $len = $msg->headers->content_length;

                    my $size = $msg->content->progress;
                    $headers = $msg->headers if !$headers;
                    my $current = int($size / ($len / 100));
                    # Don't spam the webui, update only every 5 seconds
                    if (time - $last_updated > 5) {
                        update_setup_status;
                        toggle_asset_lock($asset, 1);
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            print $log "CACHE: Downloading $asset: ", $size == $len ? 100 : $progress . "%\n";
                        }
                    }
                });
        });

    $tx = $ua->start($tx);

    if ($tx->res->code == 304) {
        if (toggle_asset_lock($asset, 0)) {
            print $log "CACHE: Content has not changed, not downloading the $asset but updating last use\n";
        }
        else {
            print $log "CACHE: Abnormal situation, bailing out\n";
            $asset = undef;
        }
    }
    elsif ($tx->res->is_success) {
        $etag = $headers->etag;
        unlink($asset);
        $asset = $tx->res->content->asset->move_to($asset)->path;
        my $size = (stat $asset)[7];
        if ($size == $headers->content_length) {
            check_limits($size);
            update_asset($asset, $etag, $size);
            print $log "CACHE: Asset download sucessful to $asset, Cache size is: $cache_real_size\n";
        }
        else {
            print $log "CACHE: Size of $asset differs, Expected: "
              . $headers->content_length
              . " / Downloaded: "
              . $size . "\n";
            $asset = undef;
        }
    }
    else {
        print $log "CACHE: Download of $asset failed with: "
          . $tx->res->code . " - "
          . $tx->res->error->{message} . "\n";
        purge_asset($asset);
        $asset = undef;
    }

    return $asset;
}

sub get_asset {
    my ($job, $asset_type, $asset) = @_;
    my $type;
    my $result;
    my $ret;
    $asset = catdir($location, basename($asset));

    while () {

        log_debug "CACHE: Aquiring lock for $asset in the database";
        $result = try_lock_asset($asset);
        if (!$result) {
            update_setup_status;
            log_debug "CACHE: Waiting 5 seconds for the lock.";
            sleep 5;
            next;
        }
        $ret = download_asset($job->{id}, lc($asset_type), $asset, ($result->{etag}) ? $result->{etag} : undef);

        if (!$ret) {
            return undef;
        }

        last;
    }

    return $asset;
}

sub toggle_asset_lock {
    my ($asset, $toggle) = @_;
    my $sql = "UPDATE assets set downloading = ?, filename = ?, last_use = strftime('%s','now') where filename = ?";

    eval { $dbh->prepare($sql)->execute($toggle, $asset, $asset) or die $dbh->errstr; };

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    else {
        return 1;
    }

}

sub try_lock_asset {
    my ($asset) = @_;
    my $sth;
    my $sql;
    my $lock_granted;
    my $result;

    eval {
        $sql
          = "SELECT (last_use > strftime('%s','now') - 60 and downloading = 1) as is_fresh, etag from assets where filename = ?";
        $sth = $dbh->prepare($sql);
        $result = $dbh->selectrow_hashref($sql, undef, $asset);
        if (!$result) {
            add_asset($asset);
            $lock_granted = 1;
            $result       = {};
        }
        elsif (!$result->{is_fresh}) {
            $lock_granted = toggle_asset_lock($asset, 1);
        }
        elsif ($result->{is_fresh} == 1) {
            log_info "CACHE: Being downloaded by another worker, sleeping.";
            $lock_granted = 0;
        }
        else {
            die "CACHE: Abnormal situation.";
        }
    };

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    else {
        if ($lock_granted) {
            return $result;
        }
        else {
            return 0;
        }
    }

}

sub add_asset {
    my ($asset, $toggle) = @_;
    my $sql = "INSERT INTO assets (downloading,filename,last_use) VALUES (1, ?, strftime('%s','now'));";
    eval { $dbh->prepare($sql)->execute($asset) or die $dbh->errstr; };

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    else {
        return 1;
    }

}

sub update_asset {
    my ($asset, $etag, $size) = @_;
    my $sql
      = "UPDATE assets set downloading = 0, filename =?, etag =? , size = ?, last_use = strftime('%s','now') where filename = ?;";
    eval {
        my $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $asset);
        $sth->bind_param(2, $etag);
        $sth->bind_param(3, $size);
        $sth->bind_param(4, $asset);

        $sth->execute;
    };

    $cache_real_size += $size;

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    else {
        log_info "CACHE: updating the $asset with $etag and $size";
        return 1;
    }

}

sub purge_asset {
    my ($asset) = @_;
    my $sql = "DELETE FROM assets WHERE filename = ?";

    eval {
        $dbh->prepare($sql)->execute($asset) or die $dbh->errstr;
        unlink($asset) or eval { log_error "CACHE: Could not remove $asset" if -e $asset };
        log_debug "CACHE: removed $asset";
    };

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    return 1;
}

sub cache_cleanup {
    my @assets = `find $location -maxdepth 1 -type f -name '*.img' -o -name '*.qcow2' -o -name '*.iso'`;
    foreach my $file (@assets) {
        my $asset_size;
        chomp $file;
        $asset_size = (stat $file)[7];
        $cache_real_size += $asset_size if asset_lookup($file);
    }
}

sub asset_lookup {
    my ($asset) = @_;
    my $sth;
    my $sql;
    my $lock_granted;
    my $result;

    $sql    = "SELECT filename, etag, last_use, size from assets where filename = ?";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql, undef, $asset);
    if (!$result) {
        log_info "CACHE: Purging non registered $asset";
        purge_asset($asset);
        return 0;
    }
    else {
        return $result;
    }

}

sub check_limits {
    # Trust the filesystem.
    my ($needed) = @_;
    my $sql;
    my $sth;
    my $result;

    my $wanted_size = $cache_real_size + $needed;

    while ($cache_real_size + $needed > $limit) {
        $sql    = "SELECT size, filename FROM assets WHERE downloading = 0 ORDER BY last_use asc";
        $sth    = $dbh->prepare($sql);
        $result = $dbh->selectrow_hashref($sql);

        foreach my $asset ($result) {
            if (purge_asset($asset->{filename})) {
                $cache_real_size -= $asset->{size};
                log_debug "Reclaiming " . $asset->{size} . " from $cache_real_size to make space for $limit";
            }    # purge asset will die anyway in case of failure.
            last if ($cache_real_size < $limit);
        }
    }
    log_debug "CACHE: Health: Real size: $cache_real_size, Configured limit: $limit";
}

1;

__DATA__
CREATE TABLE "assets" ( `etag` TEXT, `size` INTEGER, `last_use` DATETIME NOT NULL, `downloading` boolean NOT NULL, `filename` TEXT NOT NULL UNIQUE, PRIMARY KEY(`filename`) );