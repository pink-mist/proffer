#!/usr/bin/perl

use v5.10.0;
use strict;
use warnings;
use feature ':5.10';
use Text::ParseWords;
use Cwd 'abs_path';
use File::Basename;
use File::HomeDir;

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

my $debug = 1;

#default values
my $channels    = '';
my $slots       = 2;
my $slots_user  = 1;
my $queues      = 10;
my $queues_user = 3;
my $hide        = 1;

my @files = ();
my @queue = ();
my $state = {
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
 * \002/set proffer_hide\002 -- set to 1 to hide xdcc commands (default is 1)
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
	read_state();
}

sub do_add {
	my $data = shift;
	my ($path, $msg) = @$data;
	if (not defined $path) { return undef; }
	print "Debug: $path" if $debug;
	if ($path =~ /^~/) { my $home = File::HomeDir->my_home(); $path =~ s/^~/$home/; }
	$path = abs_path($path);

	my @return = ();
	if (file_exists($path)) { @return = ("Couldn't add $path. It is already in the xdcc list."); }
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

sub do_mov {
	my $data = shift;
	print "Debug: $data" if $debug;
	my ($from, $to) = @$data;
	if (($from !~ /^\d+$/) || ($to !~ /^\d+$/)) { return undef; }
	$from--; $to--;
	if (($from < 0) || ($to < 0) || ($from > $#files) || ($to > $#files)) {
		return sprintf("Index out of bounds. Must be between %d and %d.", 1, $#files+1); }
	if ($from == $to) { return "Can't move file to itself."; }

	my $item = splice(@files, $from, 1);
	my @end = splice(@files, $to);
	push @files, $item, @end;

	return sprintf("Moved %s to %d.", $item->{'name'}, $to+1);
}

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

sub save_state {
	my $state_file;
	if (HAVE_IRSSI) { $state_file = Irssi::get_irssi_dir() . '/proffer.state'; }
	else { $state_file = File::HomeDir->my_home() . '/.proffer.state'; }

	open (my $fh, '>', $state_file);
	print $fh join("\n",
			$state->{'transferred'},
			$state->{'record_speed'},
			$state->{'record_transfer'},
			map {$_->{'downloads'} . " " . $_->{'file'}} @files);
	close ($fh);
}

sub read_state {
	my $state_file;
	if (HAVE_IRSSI) { $state_file = Irssi::get_irssi_dir() . '/proffer.state'; }
	else { $state_file = File::HomeDir->my_home() . '/.proffer.state'; }
	if (!-f $state_file) { return; }

	open (my $fh, '<', $state_file);
	my @lines = <$fh>;
	close ($fh);
	chomp(@lines);

	$state->{'transferred'}     = shift @lines;
	$state->{'record_speed'}    = shift @lines;
	$state->{'record_transfer'} = shift @lines;

	foreach my $line (@lines) {
		if ($line =~ /^(\d+) (.*)$/) {
			my $dls = $1; my $file = $2;
			my $add_status = do_add([$file]);
			if ($add_status =~ /^Added /) { $files[$#files]->{'downloads'} = $dls; }
		}
		else { die "Could not properly parse state file $state_file. Has it been corrupted?"; }
	}
}

sub do_queue {
	my ($id, $pack) = @_;

	my $spot = 1;
	if (grep { ($_->{'id'} eq $id) and ($_{'pack'} eq $pack) } @queue) { return "You already queued pack #$pack."; }

	push @queue, { id => $id, pack => $pack };
  return sprintf("Added you to the main queue for pack #%d in position %d.", $pack, $#queue);
}

sub slots_available {
	if (HAVE_IRSSI) {
		my @dccs = grep { $_->{'type'} eq 'SEND' } Irssi::Irc::dccs();
		return $slots - scalar(@dccs);
	}
	else { return 0; }
}

sub user_slots_available {
	my $id = shift;
	if (HAVE_IRSSI) {
		$id =~ /^(.*), (.*)$/; my ($tag, $nick) = ($1, $2);
		my @dccs = grep {
					($_->{'type'}      eq 'SEND') and
					($_->{'servertag'} eq $tag  ) and
					($_->{'nick'}      eq $nick ) } Irssi::Irc::dccs();
		return $slots_user - scalar(@dccs);
	}
	else { return 0; }
}

sub queues_available {
	return $queues - scalar(@queue);
}

sub user_queues_available {
	my $id = shift;
	my @user_queue = grep {$_->{'id'} eq $id} @queue;
	return $queues_user - scalar(@user_queue);
}


# Irssi specific routines
sub irssi_init {
	require Irssi::Irc;
	Irssi::settings_add_str(   'proffer', 'proffer_channels',    $channels);
	Irssi::settings_add_int(   'proffer', 'proffer_slots',       $slots);
	Irssi::settings_add_int(   'proffer', 'proffer_slots_user',  $slots_user);
	Irssi::settings_add_int(   'proffer', 'proffer_queues',      $queues);
	Irssi::settings_add_int(   'proffer', 'proffer_queues_user', $queues_user);
	Irssi::settings_add_bool(  'proffer', 'proffer_hide',        $hide);
	Irssi::command_bind(       'proffer_add',                    \&irssi_add);
	Irssi::command_bind(       'proffer_add_ann',                \&irssi_add_ann);
	Irssi::command_bind(       'proffer_announce',               \&irssi_announce);
	Irssi::command_bind(       'proffer_del',                    \&irssi_del);
	Irssi::command_bind(       'proffer_mov',                    \&irssi_mov);
	Irssi::command_bind(       'proffer_list',                   \&irssi_list);
	Irssi::signal_add(         'setup changed',                  \&irssi_reload);
	Irssi::signal_add_first(   'message private',                \&irssi_handle_pm);
	irssi_reload();
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
	Irssi::print($return);
}

sub irssi_list {
	my $nick = '';
	my $server = Irssi::active_server();
	if (defined $server) { $nick = $server->{'nick'}; }
	Irssi::print(return_list($nick));
}

sub irssi_reload {
	$channels    = Irssi::settings_get_str( 'proffer_channels');
	$slots       = Irssi::settings_get_int( 'proffer_slots');
	$slots_user  = Irssi::settings_get_int( 'proffer_slots_user');
	$queues      = Irssi::settings_get_int( 'proffer_queues');
	$queues_user = Irssi::settings_get_int( 'proffer_queues_user');
	$hide        = Irssi::settings_get_bool('proffer_hide');
	Irssi::print('proffer updated.') if $debug;
}

sub irssi_handle_pm {
	my ($server, $msg, $nick, $host) = @_;
  if ($msg =~ /^xdcc /i) {
		if (irssi_check_channels($server, $nick)) {
			Irssi::signal_stop() if $hide;
			my $return = irssi_handle_xdcc($server, $nick, $msg);
			Irssi::print($return) if defined $return;
		}
	}
}

sub irssi_check_channels {
	my ($server, $nick) = @_;

	#go through each channel that is also in $channels variable
	my @channels = grep { $_->{'name'} ~~ [split(' ', $channels)] } $server->channels();
	foreach my $chan (@channels) {
		if ($chan->nick_find($nick)) { return 1; }
	}

	return 0;
}

sub irssi_handle_xdcc {
	my ($server, $nick, $msg) = @_;
  given ($msg) {
		when (/^xdcc list$/i)         { irssi_reply($server, $nick, return_list($server->{'nick'})); }
		when (/^xdcc send #?(\d+)$/i) { my $pack = $1; irssi_try_send($server, $nick, $pack); }
		when (/^xdcc info #?(\d+)$/i) { my $pack = $1; }
		when (/^xdcc stop$/i)         { }
		when (/^xdcc cancel$/i)       { }
		when (/^xdcc remove$/i)       { }
	}
}

sub irssi_reply {
	my ($server, $nick, $msg) = @_;

	foreach (split("\n", $msg)) {
		$server->send_message($nick, $_, 1);
	}
}

sub irssi_try_send {
	my ($server, $nick, $pack) = @_;
	my $tag = $server->{'tag'}; # use "$tag, $nick" to identify a specific nick on a specific server

	if (slots_available() and user_slots_available("$tag, $nick")) { irssi_send($server, $nick, $pack); }
	elsif (queues_available() and user_queues_available("$tag, $nick")) { irssi_reply($server, $nick, do_queue("$tag, $nick", $pack)); }
}

sub irssi_send {
	my ($server, $nick, $pack) = @_;
	my $file = $files[$pack++];
	$file->{'downloads'}++;
	my $name = $file->{'name'};
	$file = $file->{'file'};

	irssi_reply($server, $nick, "Sending you file $name. Resume supported.");
	$server->command("dcc send $nick \"$file\"");
}

if (HAVE_IRSSI) {
	our %IRSSI = %info;
	init();
	irssi_init();
}
else {
	die "You need to run this inside irssi!\n";
}

sub UNLOAD {
	save_state();
	Irssi::print("Shutting down proffer.") if $debug;
}



