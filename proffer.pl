#!/usr/bin/perl

use v5.10.0;
use strict;
use warnings;
use feature ':5.10';
use Text::ParseWords;
use Cwd 'abs_path';
use File::Basename;

use Data::Dumper;

our $VERSION = v0.1.0;

our %info = (
	author      => 'pink_mist',
	contact     => '#shameimaru@irc.rizon.net',
	url         => 'http://github.com/pink-mist/proffer',
	name        => 'proffer',
	description => 'adds xdcc bot functionality to your irssi',
	license     => 'BSD'
);

# 0.1.0 - First version, only some things functioning

our $debug = 1;

#default values
our $channels    = '';
our $slots       = 2;
our $slots_user  = 1;
our $queues      = 10;
our $queues_user = 3;

our @files = ();
our @queue = ();
our $state = {
	transferred     => 0,
	record_speed    => 0,
	record_transfer => 0
};

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
 * \002/proffer_list\002 -- list the files on the bot
\002---------------------------------------------------------------------------------
END
  chomp($introstr);
	printf($introstr, $VERSION);
}

sub do_add {
	my $data = shift;
	my ($path, $msg) = @$data;
	if (not defined $path) { return undef; }
	print "Debug: $path" if $debug;
	$path = abs_path($path);

	my @return = ();
	if (file_exists($path)) { @return = ("$path is already in the xdcc list."); }
	elsif (-f $path) {
		my ($fname, undef, undef) = fileparse($path);
		push @files, { downloads => 0, file => $path , name => $fname };
		if (defined $msg) { do_announce( [ scalar(@files), $msg ] ); }
		@return = ("Added $path.");
	}
	elsif (-d $path) {
		opendir(my $dh, $path) or return "Could not open dir: $path.";
		my @paths = sort grep {!/^\./} readdir($dh);
		closedir($dh);
		#foreach (@paths) { push @return, "Should add: $_"; }
		foreach (@paths) { push @return, do_add( ["$path/$_", $msg] ); }
		if (not @paths) { push @return, "No file found in $path."; }
	}
	else { @return = ("Could not stat $path."); }
	return join("\n", @return);
}

sub file_exists {
	my $file = shift;
	if (grep {$_->{'file'} eq $file} @files) { return 1; }
	return 0;
}

sub do_announce {
	my $data = shift;
	my ($num, $msg) = @$data;
	if (HAVE_IRSSI) {
		foreach my $channel (split(" ", $channels)) {
			my $server = Irssi::channel_find($channel)->server;
			if (not $server->{'connected'}) { next; }

			my $file = $files[$num-1]->{'name'};
			my $nick = $server->{'nick'};
			my $message = "[$msg] $file - /msg $nick xdcc send #$num";
			$server->command("MSG $channel $message");
		}
	}
}

sub do_del {
	my $num = shift;
	if ($num !~ /^\d+$/) { return undef; }

	my $file = $files[$num-1];
	delete $files[$num-1];
	return sprintf("Deleted %s, downloaded %d times.", $file->{'name'}, $file->{'downloads'});
}

sub do_mov { return "Unimplemented."; }

sub return_list {
	my $nick = shift;
	my $msg_beg = <<END;
** %d packs ** %d of %d slots open, Record: %s/s
** Bandwidth usage ** Current: %s/s, Record: %s/s
** To request a file, type "/msg %s xdcc send #x" **
END

	my $msg_end = <<END;
Total Offered: %s  Total transferred: %s
END
	chomp($msg_end);

	my $num = 1;
	my $total = 0;
	my @return = map {
				$total += -s $_->{'file'};
				sprintf("#%-4d %4dx [%4s] %s", $num++, $_->{'downloads'}, byte_suffix(-s $_->{'file'}), $_->{'name'})
			} @files;

	return sprintf($msg_beg, $num-1, open_slots(), $slots, byte_suffix_dec($state->{'record_speed'}),
			current_speed(), byte_suffix_dec($state->{'record_transfer'}), $nick) .
			join("\n", @return, sprintf($msg_end, byte_suffix_dec($total), byte_suffix_dec($state->{'transferred'})));
}

sub current_speed {
	return byte_suffix_dec(0);
}

sub open_slots {
	return 0;
}

sub byte_suffix {
	my $size = shift;
	my $suffix = 'B';
	if ($size >= 1000) { $size = int($size/1024); $suffix = 'k';
		if ($size >= 1000) { $size = int($size/1024); $suffix = 'M';
			if ($size >= 1000) { $size = int($size/1024); $suffix = 'G';
				if ($size >= 1000) { $size = int($size/1024); $suffix = 'T';
	} } } }
	return "$size$suffix";
}

sub byte_suffix_dec {
	my $size = shift;
	my $suffix = 'B';
	if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'k';
		if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'M';
			if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'G';
				if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'T';
	} } } }
	return "$size$suffix";
}

sub irssi_init {
	Irssi::settings_add_str(   'proffer', 'proffer_channels',    $channels);
	Irssi::settings_add_int(   'proffer', 'proffer_slots',       $slots);
	Irssi::settings_add_int(   'proffer', 'proffer_slots_user',  $slots_user);
	Irssi::settings_add_int(   'proffer', 'proffer_queues',      $queues);
	Irssi::settings_add_int(   'proffer', 'proffer_queues_user', $queues_user);
	Irssi::command_bind(       'proffer_add',                    \&irssi_add);
	Irssi::command_bind(       'proffer_add_ann',                \&irssi_add_ann);
	Irssi::command_bind(       'proffer_announce',               \&irssi_announce);
	Irssi::command_bind(       'proffer_del',                    \&irssi_del);
	Irssi::command_bind(       'proffer_mov',                    \&irssi_mov);
	Irssi::command_bind(       'proffer_list',                   \&irssi_list);
	Irssi::signal_add(         'setup changed',                  \&irssi_reload);
}

sub irssi_add {
	my ($data, $server, $witem) = @_;
	my @parse = ($data);
	my $return = do_add(\@parse) || "\002proffer:\002 add -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_add_ann {
	my ($data, $server, $witem) = @_;
	my @parse = parse_line(" ", 0, $data);
	my $return = do_add(\@parse) || "\002proffer:\002 add_ann -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_announce {
	my ($data, $server, $witem) = @_;
	my @parse = parse_line(" ", 0, $data);
	my $return = do_announce(\@parse) || "\002proffer:\002 announce -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_del {
	my ($data, $server, $witem) = @_;
	my @parse = ($data);
	my $return = do_del(\@parse) || "\002proffer:\002 del -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_mov {
	my ($data, $server, $witem) = @_;
	my @parse = quotewords(" ", 0, $data);
	my $return = do_mov(\@parse) || "\002proffer:\002 mov -- erroneous arguments: $data";
	Irssi::print(do_mov($data));
}

sub irssi_list {
	my $nick = '';
	my $server = Irssi::active_server();
	if (defined $server) { $nick = $server->{'nick'}; }
	Irssi::print(return_list($nick));
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



