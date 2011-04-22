#!/usr/bin/env perl
use strict;
use warnings;

use IO::Handle::Util qw(io_from_getline);

use JSON;

use Plack::Request;
use Plack::Response;

use DBI;
use File::HomeDir;
use JSON::XS 'encode_json';
use Path::Class 'dir';
use Time::Piece;

my $speed = 2;

my $home = File::HomeDir->my_home;
my @dir = sort {
    $b->stat->mtime <=> $a->stat->mtime
} dir("$home/Library/Application Support/MobileSync/Backup")->children;

my $mbdb = process_mbdb_file($dir[0]->file('Manifest.mbdb'));
my $mbdx = process_mbdx_file($dir[0]->file('Manifest.mbdx'));

my $dbfile;
for my $key (keys %{ $mbdb }) {
     $dbfile = $mbdx->{$mbdb->{$key}{start_offset}};
}
die unless $dbfile;

$dbfile = $dir[0]->file($dbfile)->stringify;

#CREATE TABLE WifiLocation (MAC TEXT, Timestamp FLOAT, Latitude FLOAT, Longitude FLOAT, HorizontalAccuracy FLOAT, Altitude FLOAT, VerticalAccuracy FLOAT, Speed FLOAT, Course FLOAT, Confidence INTEGER, PRIMARY KEY (MAC));
my $dbh = DBI->connect('dbi:SQLite:dbname=' . $dbfile);
my $sth = $dbh->prepare('SELECT Timestamp, Latitude, Longitude FROM WifiLocation ORDER BY Timestamp');
$sth->execute;
my $itr = sub {
    my $row = $sth->fetchrow_hashref;
    return unless $row;
    my $t = localtime($row->{Timestamp} + 31 * 365.25 * 24 * 60 * 60);
    +{
        time  => '' . $t,
        epoch => $t->epoch,
        lat   => $row->{Latitude},
        lon   => $row->{Longitude},
    }
};

my $boundary = '|||';
my $app = sub {
    my $req = Plack::Request->new(shift);
    my $path;
    if ($req->path eq '/') {
        $path = './index.html';
    } elsif ($req->path eq '/js/DUI.js') {
        $path = './DUI.js';
    } elsif ($req->path eq '/js/Stream.js') {
        $path = './Stream.js';
    } elsif ($req->path eq '/stream') {
        my $count = 0;
        my $last_at = 0;
        my $body = io_from_getline sub {
            $count++;
            sleep $speed;
            my $row;
            while (1) {
                $row = $itr->();
                return unless $row;
                next if $last_at + 60 > $row->{epoch};
                $last_at = $row->{epoch};
                last;
            }
            my $ret = "--$boundary\nContent-Type: application/javascript\n";
            $ret .= to_json({
                time => $row->{time},
                lat  => $row->{lat},
                lon  => $row->{lon},
            });
            warn $ret;
            return $ret;
        };

        return [ 200, ['Content-Type' => qq{multipart/mixed; boundary="$boundary"} ], $body ];
    } else {
        my $res = Plack::Response->new(404);
        $res->body('not found');
        return $res->finalize;
    }
    open my $fh, '<', $path;
    my $res = Plack::Response->new(200);
    $res->body($fh);
    return $res->finalize;
};


sub process_mbdb_file {
    my ($mbdb) = @_;

    my $fh = $mbdb->openr;
    $fh->binmode;

    my $buffer;
    $fh->read($buffer, 4);
    die if $buffer ne 'mbdb';

    $fh->read($buffer, 2);
    my $offset = 6;

    my $data = +{};
    while ($offset < $mbdb->stat->size) {
        my $fileinfo = +{};
        $fileinfo->{start_offset} = $offset;
        $fileinfo->{domain}       = getstring($fh, \$offset);
        $fileinfo->{filename}     = getstring($fh, \$offset);
        $fileinfo->{linktarget}   = getstring($fh, \$offset);
        $fileinfo->{datahash}     = getstring($fh, \$offset);
        $fileinfo->{unknown1}     = getstring($fh, \$offset);
        $fileinfo->{mode}         = getint($fh, 2, \$offset);
        $fileinfo->{unknown2}     = getint($fh, 4, \$offset);
        $fileinfo->{unknown3}     = getint($fh, 4, \$offset);
        $fileinfo->{userid}       = getint($fh, 4, \$offset);
        $fileinfo->{groupid}      = getint($fh, 4, \$offset);
        $fileinfo->{mtime}        = getint($fh, 4, \$offset);
        $fileinfo->{atime}        = getint($fh, 4, \$offset);
        $fileinfo->{ctime}        = getint($fh, 4, \$offset);
        $fileinfo->{filelen}      = getint($fh, 8, \$offset);
        $fileinfo->{flag}         = getint($fh, 1, \$offset);
        $fileinfo->{numprops}     = getint($fh, 1, \$offset);
        $fileinfo->{properties}   = +{};
        for (1 .. $fileinfo->{numprops}) {
            my $key   = getstring($fh, \$offset);
            my $value = getstring($fh, \$offset);
            $fileinfo->{properties}{$key} = $value;
        }
        # 必要なのはこれが含まれているものだけ
        if ($fileinfo->{filename} eq 'Library/Caches/locationd/consolidated.db') {
            $data->{$fileinfo->{start_offset}} = $fileinfo;
        }
    };

    return $data;
}

sub process_mbdx_file {
    my ($mbdx) = @_;

    my $fh = $mbdx->openr;
    $fh->binmode;

    my $buffer;
    $fh->read($buffer, 4);
    die if $buffer ne 'mbdx';

    $fh->read($buffer, 2);
    my $offset = 6;

    my $filecount = getint($fh, 4, \$offset);
    my $data = +{};
    while ($offset < $mbdx->stat->size) {
        $fh->read($buffer, 20);
        $offset += 20;
        my $file_id = unpack("H*", $buffer);
        my $mbdb_offset = getint($fh, 4, \$offset);
        my $mode = getint($fh, 2, \$offset);
        $data->{$mbdb_offset + 6} = $file_id;
    }

    return $data;
}

sub getint {
    my ($fh, $size, $offset) = @_;

    $fh->read(my $buffer, $size);
    $$offset += $size;
    return oct('0x' . unpack("H*", $buffer));
}

sub getstring {
    my ($fh, $offset) = @_;

    my $buffer;

    $fh->read($buffer, 2);
    $$offset += 2;
    my $unpacked = unpack('H*', $buffer);
    return '' if $unpacked eq 'ffff';

    my $length = oct("0x${unpacked}");
    $fh->read($buffer, $length);
    $$offset += $length;
    return $buffer;
}

$app;
