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

our $VERSION = v0.2.1;

our %info = (
	author      => 'pink_mist',
	contact     => '#shameimaru@irc.rizon.net',
	url         => 'http://github.com/pink-mist/proffer',
	name        => 'proffer',
	description => 'adds xdcc bot functionality to your irssi',
	license     => 'BSD'
);

# 0.2.1 - Bugfix release: fixed rename-tracking for dcc sends as well
# 0.2.0 - Every needed command is implemented, properly tracks nicks, and now uses /notice instead of /msg
# 0.1.1 - Most things are working, you can actually use it in a limited capacity
# 0.1.0 - First version, only some things functioning

my $debug = 1;

#default values
my $channels      = '';
my $slots         = 2;
my $slots_user    = 1;
my $queues        = 10;
my $queues_user   = 3;
my $hide          = 1;
my $list_deny     = '';
my $list_file     = '';
my $restrict_send = 0;

my @files = ();
my @queue = ();
my $state = {
	transferred     => 0,
	record_speed    => 0,
	record_transfer => 0
};
my @renames = ();

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
 * \002/set proffer_list_deny <msg>\002 -- set to deny xdcc lists and respond instead with msg
 * \002/set proffer_list_file <file>\002 -- set to keep file updated with current xdcc list
 * \002/set proffer_restrict_send <val>\002 -- enable to restrict xdcc functionality to nicks
                                       in a channel with you
 * \002/proffer add <dir|file>\002 -- add every file (that isn't already added) in a
                              directory or a specific file
 * \002/proffer add_ann <dir|file>\002 -- ditto, but also announce the file-add
 * \002/proffer announce <num> [msg]\002 -- announce a file with optional message
 * \002/proffer del <num>\002 -- delete a file from the bot
 * \002/proffer mov <from> <to>\002 -- move a file from the bot
 * \002/proffer list\002 -- list the files on the bot
\002---------------------------------------------------------------------------------
END
	chomp($introstr);
	printf($introstr, $VERSION) unless $hide;
	read_state();
}

sub do_add {
	my $data = shift;
	my ($path, $msg) = @$data;
	if (not defined $path) { return undef; }
	print "Debug: $path" if ($debug > 1);
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
	update_file() if ($list_file ne '');
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
	if ($num !~ /^\d+$/) { return 0; }
	if (not defined $files[$num-1]) { return 0; }
	my @channels = ();
	if (HAVE_IRSSI) {
		foreach my $channel (split(" ", $channels)) {
			my $server = Irssi::channel_find($channel)->{'server'};
			if (not $server->{'connected'}) { next; }
			push @channels, $channel;

			my $file = $files[$num-1]->{'name'};
			my $nick = $server->{'nick'};
			my $message = "[\002$msg\002] $file - /msg $nick xdcc send #$num";
			$server->send_message($channel, $message, 0);
		}
	}
	print "Announced pack $num in channels: " . join(" ", @channels);
	return 1;
}

sub do_del {
	my $num = shift;
	if ($num !~ /^\d+$/) { return undef; }

	my $file = $files[$num-1];
	delete $files[$num-1];
	update_file() if ($list_file ne '');
	return sprintf("Deleted %s, downloaded %d times.", $file->{'name'}, $file->{'downloads'});
}

sub do_mov {
	my $data = shift;
	print "Debug: $data" if ($debug > 1);
	my ($from, $to) = @$data;
	if (($from !~ /^\d+$/) || ($to !~ /^\d+$/)) { return undef; }
	$from--; $to--;
	if (($from < 0) || ($to < 0) || ($from > $#files) || ($to > $#files)) {
		return sprintf("Index out of bounds. Must be between %d and %d.", 1, $#files+1); }
	if ($from == $to) { return "Can't move file to itself."; }

	my $item = splice(@files, $from, 1);
	my @end = splice(@files, $to);
	push @files, $item, @end;
	update_file() if ($list_file ne '');

	return sprintf("Moved %s to %d.", $item->{'name'}, $to+1);
}

sub return_list {
	my $nick = shift;
	my $msg_beg = <<END;
**  %d packs  **  %d of %d slots open, Record: %s/s
**  Bandwidth usage  **  Current: %s/s, Record: %s/s
**  To request a file, type "/msg %s xdcc send #x"  **
END

	my $msg_end = <<END;
Total offered: %s  Total transferred: %s
END
	chomp($msg_end);

	my $num = 0;
	my $total = 0;
	my @return = map {
				$total += -s $_->{'file'};
				sprintf("#%-4d %4dx [%4s] %s", ++$num, $_->{'downloads'}, byte_suffix(-s $_->{'file'}), $_->{'name'})
			} @files;

	return sprintf($msg_beg, $num, slots_available(), $slots, byte_suffix_dec($state->{'record_speed'}),
			current_speed(), byte_suffix_dec($state->{'record_transfer'}), $nick) .
			join("\n", @return, sprintf($msg_end, byte_suffix_dec($total), byte_suffix_dec($state->{'transferred'})));
}

sub current_speed {
	if (HAVE_IRSSI) { return byte_suffix_dec(irssi_current_speed()); }
	else { return byte_suffix_dec(0); }
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
	if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'kB';
		if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'MB';
			if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'GB';
				if ($size >= 1000) { $size = int(($size/1024)*100)/100; $suffix = 'TB';
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

	if (grep { ($_->{'id'} eq $id) and ($_->{'pack'} eq $pack) } @queue) { return "You already queued pack #$pack."; }

	push @queue, { id => $id, pack => $pack };
	update_file() if ($list_file ne '');
  return sprintf("Added you to the main queue for pack #%d in position %d.", $pack, $#queue+1);
}

sub slots_available {
	if (HAVE_IRSSI) {
		my @dccs = grep { $_->{'type'} eq 'SEND' } Irssi::Irc::dccs();
		return max($slots - scalar(@dccs), 0);
	}
	else { return 0; }
}

sub user_slots_available {
	my $id = shift;
	if (HAVE_IRSSI) {
		$id =~ /^(.*), (.*)$/; my ($tag, $nick) = ($1, $2);
		my @ids = map { $_->{'id'} } grep { $_->{'tag'} eq $tag and $_->{'nick'} eq $nick } @renames;
		my @dccs = grep {
					(($_->{'type'} eq 'SEND') and ($_->{'servertag'} eq $tag) and ($_->{'nick'} eq $nick )) or
					($_->{'_irssi'} ~~ [@ids])
				} Irssi::Irc::dccs();

		return max($slots_user - scalar(@dccs),0);
	}
	else { return 0; }
}

sub queues_available {
	return max($queues - scalar(@queue),0);
}

sub user_queues_available {
	my $id = shift;
	my @user_queue = grep {$_->{'id'} eq $id} @queue;
	return max($queues_user - scalar(@user_queue),0);
}

sub pack_info {
	my $pack = shift;
	my $file = $files[$pack-1];
	if (not defined $file) { return "Invalid pack number. Try again."; }

	my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = stat($file->{'file'});

	return sprintf("Pack info for pack #%d:\n" .
			" Filename       %s\n" .
			" Filesize       %d [%s]\n" .
			" Last Modified  %s\n" .
			" Gets           %d", $pack, $file->{'name'}, $size, byte_suffix_dec($size), scalar(gmtime($mtime)), $file->{'downloads'});
}

sub update_file {
	my $lines = return_list(Irssi::active_server()->{'nick'});
	my $fh;
	my $fname = $list_file; my $home = File::HomeDir->my_home();
	$fname =~ s/^~/$home/;
	if (not open($fh, '>', $fname)) { warn "Could not open file $list_file: $!"; return; };
	print $fh $lines;
	close $fh;
}

sub remove_queues {
	my $id = shift;
	my $num = @queue;
	@queue = grep { $_->{'id'} ne $id } @queue;
	if ($num != scalar(@queue)) { return sprintf("Removed you from %d queues.", $num-scalar(@queue)); }
	else { return "You don't appear to be in a queue."; }
}

sub max { return ($_[0] > $_[1]) ? $_[0] : $_[1]; }


# Irssi specific routines
sub irssi_init {
	require Irssi::Irc;

	# Register settings
	Irssi::settings_add_str(   'proffer', 'proffer_channels',      $channels);
	Irssi::settings_add_int(   'proffer', 'proffer_slots',         $slots);
	Irssi::settings_add_int(   'proffer', 'proffer_slots_user',    $slots_user);
	Irssi::settings_add_int(   'proffer', 'proffer_queues',        $queues);
	Irssi::settings_add_int(   'proffer', 'proffer_queues_user',   $queues_user);
	Irssi::settings_add_bool(  'proffer', 'proffer_hide',          $hide);
	Irssi::settings_add_str(   'proffer', 'proffer_list_deny',     $list_deny);
	Irssi::settings_add_str(   'proffer', 'proffer_list_file',     $list_file);
	Irssi::settings_add_bool(  'proffer', 'proffer_restrict_send', $restrict_send);
	# Bind commands
	Irssi::command_bind(       'proffer',                          \&irssi_proffer);
	Irssi::command_bind(       'proffer add',                      \&irssi_add);
	Irssi::command_bind(       'proffer add_ann',                  \&irssi_add_ann);
	Irssi::command_bind(       'proffer announce',                 \&irssi_announce);
	Irssi::command_bind(       'proffer del',                      \&irssi_del);
	Irssi::command_bind(       'proffer mov',                      \&irssi_mov);
	Irssi::command_bind(       'proffer list',                     \&irssi_list);
	Irssi::command_bind(       'proffer queue',                    \&irssi_queue);
	# Intercept signals
	Irssi::signal_add(         'setup changed',                    \&irssi_reload);
	Irssi::signal_add_first(   'message private',                  \&irssi_handle_pm);
	Irssi::signal_add(         'dcc transfer update',              \&irssi_dcc_update);
	Irssi::signal_add_last(    'dcc closed',                       \&irssi_dcc_closed);
	Irssi::signal_add_last(    'dcc error connect',                \&irssi_dcc_closed);
	Irssi::signal_add_last(    'dcc error file open',              \&irssi_dcc_closed);
	Irssi::signal_add_last(    'dcc error send exists',            \&irssi_dcc_closed);
	Irssi::signal_register(  { 'proffer next queue' =>             [] });
	Irssi::signal_add(         'proffer next queue',               \&irssi_next_queue);
	Irssi::signal_add(         'message part',                     \&irssi_check_queue);
	Irssi::signal_add(         'message kick',                     \&irssi_check_queue);
	Irssi::signal_add(         'message quit',                     \&irssi_check_queue);
	Irssi::signal_add(         'message nick',                     \&irssi_handle_nick);
	irssi_reload();
}

sub irssi_proffer {
	my ($data, $server, $item) = @_;
	$data =~ s/\s+$//g;
	Irssi::command_runsub('proffer', $data, $server, $item);
}

sub irssi_add {
	my ($data, $server, $witem) = @_;
	my @parse = ($data);
	my $return = do_add(\@parse) || "\002proffer:\002 add -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_add_ann {
	my ($data, $server, $witem) = @_;
	my $return = do_add([$data, "added"]) || "\002proffer:\002 add_ann -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_announce {
	my ($data, $server, $witem) = @_;
	my @parse = parse_line(" ", 0, $data);
	my $return = do_announce(\@parse) or Irssi::print("\002proffer:\002 announce -- erroneous arguments: $data");
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
	my $val;
	my $updated = 0;

	$val = Irssi::settings_get_str( 'proffer_channels');      if ($val ne $channels)      { $channels      = $val; $updated = 1; }
	$val = Irssi::settings_get_int( 'proffer_slots');         if ($val ne $slots)         { $slots         = $val; $updated = 1; }
	$val = Irssi::settings_get_int( 'proffer_slots_user');    if ($val ne $slots_user)    { $slots_user    = $val; $updated = 1; }
	$val = Irssi::settings_get_int( 'proffer_queues');        if ($val ne $queues)        { $queues        = $val; $updated = 1; }
	$val = Irssi::settings_get_int( 'proffer_queues_user');   if ($val ne $queues_user)   { $queues_user   = $val; $updated = 1; }
	$val = Irssi::settings_get_bool('proffer_hide');          if ($val ne $hide)          { $hide          = $val; $updated = 1; }
	$val = Irssi::settings_get_str( 'proffer_list_deny');     if ($val ne $list_deny)     { $list_deny     = $val; $updated = 1; }
	$val = Irssi::settings_get_str( 'proffer_list_file');     if ($val ne $list_file)     { $list_file     = $val; $updated = 1; }
	$val = Irssi::settings_get_bool('proffer_restrict_send'); if ($val ne $restrict_send) { $restrict_send = $val; $updated = 1; }
	Irssi::print('proffer updated.') if $debug && $updated;
	update_file() if ($list_file ne '') && $updated;
}

sub irssi_handle_pm {
	my ($server, $msg, $nick, $host) = @_;
  if ($msg =~ /^xdcc /i) {
		if ((not $restrict_send) || (irssi_check_channels($server, $nick))) {
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
	map { $_->nick_find($nick) and return 1; } @channels;

	return 0;
}

sub irssi_handle_xdcc {
	my ($server, $nick, $msg) = @_;
	my $id = $server->{'tag'} . ", $nick";
	given ($msg) {
		                                # if $list_deny is set, deny xdcc list and reply with the set message.
		when (/^xdcc list$/i)         { irssi_reply($server, $nick, ($list_deny ne '') ? "XDCC LIST DENIED. $list_deny" : return_list($server->{'nick'})) }
		when (/^xdcc send #?(\d+)$/i) { my $pack = $1; irssi_try_send($server, $nick, $pack); }
		when (/^xdcc info #?(\d+)$/i) { my $pack = $1; irssi_reply($server, $nick, pack_info($pack)); }
		when (/^xdcc cancel$/i)       { irssi_reply($server, $nick, irssi_cancel_sends($server, $nick)); }
		when (/^xdcc remove$/i)       { irssi_reply($server, $nick, remove_queues($id)); }
	}
}

sub irssi_reply {
	my ($server, $nick, $msg) = @_;

	#if the line of the message isn't empty, /notice it to $nick
	map { $_ eq '' or $server->command("NOTICE $nick $_"); } split("\n", $msg);
}

sub irssi_try_send {
	my ($server, $nick, $pack) = @_;
	my $tag = $server->{'tag'}; # use "$tag, $nick" to identify a specific nick on a specific server

	if (slots_available() and user_slots_available("$tag, $nick")) { irssi_send($server, $nick, $pack); }
	elsif (queues_available() and user_queues_available("$tag, $nick")) { irssi_reply($server, $nick, do_queue("$tag, $nick", $pack)); }
	else { irssi_reply($server, $nick, "No more queues available for you."); }
	update_file() if ($list_file ne '');
}

sub irssi_send {
	my ($server, $nick, $pack) = @_;
	my $file = $files[--$pack];
	if (not defined $file) { irssi_reply($server, $nick, "Invalid pack number. Try again."); return; }
	$file->{'downloads'}++;
	my $name = $file->{'name'};
	$file = $file->{'file'};

	irssi_reply($server, $nick, "Sending you file $name. Resume supported.");
	$server->command("dcc send $nick \"$file\"");
}

sub irssi_dcc_update {
	my $dcc = shift;

	#track renames
	unless (grep { $_->{'id'} eq $dcc->{'_irssi'} } @renames) {
		push @renames, { 'tag' => $dcc->{'servertag'}, 'id' => $dcc->{'_irssi'}, 'nick' => $dcc->{'nick'} };
	}

	#calculate speeds
	irssi_current_speed();

	#see if any send slots are available
	irssi_next_queue();
}

sub irssi_current_speed {
	my @dccs = grep { $_->{'type'} eq 'SEND' } Irssi::Irc::dccs();

	my $cum_speed = 0; #fun to shorten cumulative as cum :3
	foreach my $dcc (@dccs) {
		my $used_time = (time - $dcc->{'starttime'});
		#can't really trust the first couple of seconds of transfer speed (and it must be above 0, or we'll E_DIVZERO)
		my $speed = ($used_time > 5) ? (($dcc->{'transfd'} - $dcc->{'skipped'}) / $used_time) : 0;
		$cum_speed += $speed;
		if ($speed > $state->{'record_transfer'}) { $state->{'record_transfer'} = $speed; }
	}
	if ($cum_speed > $state->{'record_speed'}) { $state->{'record_speed'} = $cum_speed; }
	return $cum_speed;
}

sub irssi_dcc_closed {
	my $closed = shift;
	$state->{'transferred'} += ($closed->{'transfd'} - $closed->{'skipped'});
	@renames = grep { $_->{'id'} ne $closed->{'_irssi'} } @renames;
	Irssi::timeout_add_once(10, sub {  Irssi::signal_emit('proffer next queue'); }, undef);
}

sub irssi_next_queue {
	if (slots_available()) {
		my $num = 0;
		foreach my $queue (@queue) {
			if (user_slots_available($queue->{'id'})) {
				printf("Sending queue #%d to %s.", $num+1, $queue->{'id'}) unless $hide;
				my ($add) = splice(@queue, $num, 1);
				$add->{'id'} =~ /^(.*), (.*)$/; my ($tag, $nick) = ($1, $2);
				my $server = Irssi::server_find_tag($tag);
				irssi_send($server, $nick, $add->{'pack'});
				last;
			}
			else { printf("Can't send to %s.", $queue->{'id'}) if ($debug > 2); }
			$num++;
		}
	}
	else { print "irssi_next_queue: no slots available :(" if ($debug > 2); }
	print "irssi_next_queue: finished." if ($debug > 2);
	update_file() if ($list_file ne '');
}

sub irssi_queue {
	my $num = 0;
	map {
			printf("Queue %d: %s -> %d (%s)", ++$num, $_->{'id'}, $_->{'pack'}, $files[$_->{'pack'}-1]->{'name'});
		} @queue;
	print "proffer: End of queue.";
}

sub irssi_cancel_sends {
	my ($server, $nick) = @_;
	my @dccs = grep { $_->{'type'} eq 'SEND' and
				$_->{'servertag'} eq $server->{'tag'} and
				$_->{'nick'} eq $nick } Irssi::Irc::dccs();

	map { $_->destroy(); } @dccs;
	if (scalar(@dccs)) { return sprintf("Aborted %d sends.", scalar(@dccs)); }
	else { return "You don't have a transfer running."; }
}

sub irssi_check_queue {
	if ($restrict_send) {
		@queue = grep { $_->{'id'} =~ /^(.*), (.*)$/ and irssi_check_channels(Irssi::server_find_tag($1), $2)  } @queue;
	}
}

sub irssi_handle_nick {
	my ($server, $newnick, $oldnick, $host) = @_;
	my $tag = $server->{'tag'};
	my $oldid = "$tag, $oldnick"; my $newid = "$tag, $newnick";
	my $oldid_re = quotemeta($oldid);

	#update queue
	map { $_->{'id'} =~ s/^$oldid_re$/$newid/; } @queue;

	#update @renames list with $newnick
	map {
			$_->{'nick'} = $newnick
		} grep { $_->{'tag'} eq $tag and $_->{'nick'} eq $oldnick } @renames;
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



