#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;
use JSON::PP;

$| = 1;

my $dylib_path = shift @ARGV;
if (!$dylib_path) {
    print encode_json({
        type => "fatal",
        message => "missing dylib path"
    }) . "\n";
    exit 2;
}

my $handle = DynaLoader::dl_load_file($dylib_path, 0);
if (!$handle) {
    print encode_json({
        type => "fatal",
        message => DynaLoader::dl_error()
    }) . "\n";
    exit 3;
}

my $snapshot_symbol = DynaLoader::dl_find_symbol($handle, "keyway_mediaremote_snapshot");
my $command_symbol = DynaLoader::dl_find_symbol($handle, "keyway_mediaremote_send_command");
my $client_cache_symbol = DynaLoader::dl_find_symbol($handle, "keyway_mediaremote_refresh_client_cache");
my $register_symbol = DynaLoader::dl_find_symbol($handle, "keyway_mediaremote_register_notifications");
my $route_shield_symbol = DynaLoader::dl_find_symbol($handle, "keyway_mediaremote_set_route_shield");
my $role = $ENV{KEYWAY_MEDIAREMOTE_ROLE} // "snapshot";
if (!$snapshot_symbol || !$command_symbol || !$client_cache_symbol || !$route_shield_symbol) {
    print encode_json({
        type => "fatal",
        message => "missing helper symbols"
    }) . "\n";
    exit 4;
}

DynaLoader::dl_install_xsub("Keyway::MediaRemote::snapshot", $snapshot_symbol);
DynaLoader::dl_install_xsub("Keyway::MediaRemote::send_command", $command_symbol);
DynaLoader::dl_install_xsub("Keyway::MediaRemote::refresh_client_cache", $client_cache_symbol);
DynaLoader::dl_install_xsub("Keyway::MediaRemote::set_route_shield", $route_shield_symbol);

if ($register_symbol && !$ENV{KEYWAY_MEDIAREMOTE_DISABLE_NOTIFICATIONS}) {
    DynaLoader::dl_install_xsub("Keyway::MediaRemote::register_notifications", $register_symbol);
    Keyway::MediaRemote::register_notifications();
}

print encode_json({
    type => "ready",
    host => "/usr/bin/perl",
    role => $role,
    pid => $$
}) . "\n";

while (defined(my $line = <STDIN>)) {
    chomp $line;
    next if $line =~ /^\s*$/;

    my $message = eval { decode_json($line) };
    if ($@ || ref($message) ne "HASH") {
        print encode_json({
            type => "error",
            message => "invalid json"
        }) . "\n";
        next;
    }

    my $type = $message->{type} // "";
    local $ENV{KEYWAY_MEDIAREMOTE_REQUEST_ID} = $message->{requestID} // "";

    if ($type eq "ping") {
        print encode_json({
            type => "pong",
            requestID => $ENV{KEYWAY_MEDIAREMOTE_REQUEST_ID},
            pid => $$
        }) . "\n";
    } elsif ($type eq "refresh") {
        Keyway::MediaRemote::snapshot();
    } elsif ($type eq "refreshClientCache") {
        Keyway::MediaRemote::refresh_client_cache();
    } elsif ($type eq "sendCommand") {
        local $ENV{KEYWAY_MEDIAREMOTE_TARGET_ID} = $message->{targetID} // "";
        local $ENV{KEYWAY_MEDIAREMOTE_COMMAND} = $message->{command} // "";
        Keyway::MediaRemote::send_command();
    } elsif ($type eq "setRouteShield") {
        local $ENV{KEYWAY_MEDIAREMOTE_ROUTE_ENABLED} = $message->{enabled} ? "1" : "0";
        local $ENV{KEYWAY_MEDIAREMOTE_ROUTE_BUNDLE_IDENTIFIER} = $message->{bundleIdentifier} // "";
        local $ENV{KEYWAY_MEDIAREMOTE_ROUTE_INFO_JSON} = encode_json($message->{info} // {});
        Keyway::MediaRemote::set_route_shield();
    } else {
        print encode_json({
            type => "error",
            requestID => $ENV{KEYWAY_MEDIAREMOTE_REQUEST_ID},
            message => "unsupported request type"
        }) . "\n";
    }
}
