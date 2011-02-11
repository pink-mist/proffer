#!/usr/bin/perl

use v5.10.0;
use strict;
use warnings;
use feature ':5.10';

our $VERSION = v0.1.0;

our %info = (
	author      => 'pink_mist',
	contact     => '#shameimaru@irc.rizon.net',
	url         => 'http://www.example.com/',
	name        => 'proffer',
	description => 'adds xdcc bot functionality to your irssi',
	license     => 'BSD'
);

our $debug = 1;

#default values
our $channels    = '';
our $slots       = 2;
our $slots_user  = 1;
our $queues      = 10;
our $queues_user = 3;

BEGIN {
	*HAVE_IRSSI = Irssi->can('command_bind') ? sub {1} : sub {0};
}

sub init {
  my $introstr = <<END;
\002---------------------------------------------------------------------------------
\002proffer - acts as xdcc bot
\002Version - v%vd - Created by pink_mist (irc.rizon.net #shameimaru)
\002---------------------------------------------------------------------------------
Usage:
 * \002/help proffer\002 -- for more detailed help
 * \002/set proffer_channels <#channel1 ...>\002 -- to set which channels to be active in
 * \002/set proffer_slots <num>\002 -- number of send slots
 * \002/set proffer_slots_user <num>\002 -- number of send slots per user
 * \002/set proffer_queues <num>\002 -- number of queues
 * \002/set proffer_queues_user <num>\002 -- number of queues per user
 * \002/proffer_add <dir|file>\002 -- add every file (that isn't already added) in a
                                  directory or a specific file
 * \002/proffer_add_ann <dir|file>\002 -- ditto, but also announce the file-add
 * \002/proffer_announce <num> [msg]\002 -- announce a file with optional message
 * \002/proffer_del <num>\002 -- delete a file from the bot
 * \002/proffer_mov <from> <to>\002 -- move a file from the bot
\002---------------------------------------------------------------------------------
END
	printf($introstr, $VERSION);
}

sub do_add { return "Unimplemented."; }

sub do_add_ann { return "Unimplemented."; }

sub do_announce { return "Unimplemented."; }

sub do_del { return "Unimplemented."; }

sub do_mov { return "Unimplemented."; }

sub irssi_init {
	Irssi::settings_add_str(   'proffer', 'proffer_channels',    $channels);
	Irssi::settings_add_int(   'proffer', 'proffer_slots',       $slots);
	Irssi::settings_add_int(   'proffer', 'proffer_slots_user',  $slots_user);
	Irssi::settings_add_int(   'proffer', 'proffer_queues',      $queues);
	Irssi::settings_add_int(   'proffer', 'proffer_queues_user', $queues_user);
	Irssi::command_bind(       'proffer_add',                    \&irssi_add);
	Irssi::command_set_options('proffer_add',                    '+path');
	Irssi::command_bind(       'proffer_add_ann',                \&irssi_add_ann);
	Irssi::command_set_options('proffer_add_ann',                '+msg +path');
	Irssi::command_bind(       'proffer_announce',               \&irssi_announce);
	Irssi::command_set_options('proffer_announce',               '+num +msg');
	Irssi::command_bind(       'proffer_del',                    \&irssi_del);
	Irssi::command_set_options('proffer_del',                    '+num');
	Irssi::command_bind(       'proffer_mov',                    \&irssi_mov);
	Irssi::command_set_options('proffer_mov',                    '+from +to');
	Irssi::signal_add(         'setup changed',                  \&irssi_reload);
}

sub irssi_add {
	my ($data, $server, $witem) = @_;
	my $parse = Irssi::command_parse_options('proffer_add', $data);
	my $return = do_add($parse) || "\002proffer:\002 add -- erroneous arguments: $data";
	Irssi::print($parse);
}

sub irssi_add_ann {
	my ($data, $server, $witem) = @_;
	my $parse = Irssi::command_parse_options('proffer_add_ann', $data);
	my $return = do_add_ann($parse) || "\002proffer:\002 add_ann -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_announce {
	my ($data, $server, $witem) = @_;
	my $parse = Irssi::command_parse_options('proffer_announce', $data);
	my $return = do_announce($parse) || "\002proffer:\002 announce -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_del {
	my ($data, $server, $witem) = @_;
	my $parse = Irssi::command_parse_options('proffer_del', $data);
	my $return = do_del($parse) || "\002proffer:\002 del -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_mov {
	my ($data, $server, $witem) = @_;
	my $parse = Irssi::command_parse_options('proffer_mov', $data);
	my $return = do_mov($parse) || "\002proffer:\002 mov -- erroneous arguments: $data";
	Irssi::print(do_mov($data));
}

sub irssi_reload {
	$channels    = Irssi::settings_get_str('proffer_channels');
	$slots       = Irssi::settings_get_int('proffer_slots');
	$slots_user  = Irssi::settings_get_int('proffer_slots_user');
	$queues      = Irssi::settings_get_int('proffer_queues');
	$queues_user = Irssi::settings_get_int('proffer_queues_user');
	Irssi::print('proffer updated.') if $debug;
}

if (HAVE_IRSSI) {
	our %IRSSI = %info;
	init();
	irssi_init();
}
else {
	die "You need to run this inside irssi!\n";
}
