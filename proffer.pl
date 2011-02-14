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

our $VERSION = v0.2.2;

our %info = (
	author      => 'pink_mist',
	contact     => '#shameimaru@irc.rizon.net',
	url         => 'http://github.com/pink-mist/proffer',
	name        => 'proffer',
	description => 'adds xdcc bot functionality to your irssi',
	license     => 'BSD'
);

# 0.2.2 - Bugfix release: fixed del command which was not working
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
\002proffer - lets your irssi serve files as an xdcc bot
\002Version - v%vd - Created by pink_mist (irc.rizon.net #shameimaru)
\002---------------------------------------------------------------------------------
Basic setup:
 * /set proffer_channels <#channel1 ...>
 * /proffer add <file|dir>
For further help see \002/help proffer
\002---------------------------------------------------------------------------------
END
	chomp($introstr);
	printf($introstr, $VERSION);
	read_state();
}

sub do_add {
	my ($path, $msg) = @_;
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
		foreach (@paths) { push @return, do_add("$path/$_", $msg); }
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
	my ($num, $msg) = @_;
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
	my ($from, $to) = @_;
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
			my $add_status = do_add($file);
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
	require Irssi::TextUI;

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
	Irssi::command_bind(       'proffer queue force',              \&irssi_queue_force);
	Irssi::command_bind(       'proffer queue send',               \&irssi_queue_force);
	Irssi::command_bind(       'proffer queue del',                \&irssi_queue_del);
	Irssi::command_bind(       'proffer queue mov',                \&irssi_queue_mov);
	Irssi::command_bind(       'help',                             \&irssi_help);
	# Intercept signals
	Irssi::signal_add(         'setup changed',                    \&irssi_reload);
	Irssi::signal_add_first(   'message private',                  \&irssi_handle_pm);
	Irssi::signal_add(         'dcc transfer update',              \&irssi_dcc_update);
	Irssi::signal_add_last(    'dcc closed',                       \&irssi_dcc_closed);
	Irssi::signal_add_last(    'dcc error connect',                \&irssi_dcc_closed);
	Irssi::signal_add_last(    'dcc error file open',              \&irssi_dcc_closed);
	Irssi::signal_add_last(    'dcc error send exists',            \&irssi_dcc_closed);
	Irssi::signal_add(         'message part',                     \&irssi_check_queue);
	Irssi::signal_add(         'message kick',                     \&irssi_check_queue);
	Irssi::signal_add(         'message quit',                     \&irssi_check_queue);
	Irssi::signal_add(         'message nick',                     \&irssi_handle_nick);
	Irssi::signal_add_first(   'complete word',                    \&irssi_completion);

	# Statusbar
	Irssi::statusbar_item_register('proffer', '{sb $0-}', 'irssi_statusbar');

	irssi_reload();
}

sub irssi_proffer {
	my ($data, $server, $item) = @_;
	$data =~ s/\s+$//g;
	Irssi::command_runsub('proffer', $data, $server, $item);
}

sub irssi_add {
	my ($data, $server, $witem) = @_;
	my $return = do_add($data) || "\002proffer:\002 add -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_add_ann {
	my ($data, $server, $witem) = @_;
	my $return = do_add($data, "added") || "\002proffer:\002 add_ann -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_announce {
	my ($data, $server, $witem) = @_;
	my @parse = parse_line(" ", 0, $data);
	my $return = do_announce(@parse) or Irssi::print("\002proffer:\002 announce -- erroneous arguments: $data");
}

sub irssi_del {
	my ($data, $server, $witem) = @_;
	my $return = do_del($data) || "\002proffer:\002 del -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_mov {
	my ($data, $server, $witem) = @_;
	my @parse = quotewords(" ", 0, $data);
	my $return = do_mov(@parse) || "\002proffer:\002 mov -- erroneous arguments: $data";
	Irssi::print($return);
}

sub irssi_list {
	my $nick = defined Irssi::active_server() ? Irssi::active_server()->{'nick'} : Irssi::settings_get_str('nick');
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

	#update statusbar
	Irssi::statusbar_items_redraw('proffer');
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

	#update statusbar
	Irssi::statusbar_items_redraw('proffer');
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

	#update statusbar
	Irssi::statusbar_items_redraw('proffer');
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
	Irssi::timeout_add_once(10, \&irssi_next_queue, undef);
}

sub irssi_next_queue {
	if (slots_available()) {
		my $num = 0;
		foreach my $queue (@queue) {
			if (not exists $queue->{'id'}) { print "skipping queue." if $debug; next; } #this shouldn't be necessary ...
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

	#update statusbar
	Irssi::statusbar_items_redraw('proffer');
}

sub irssi_queue {
	my ($data, $server, $item) = @_;
	if ($data ne '') {
		Irssi::command_runsub('proffer queue', $data, $server, $item);

		#update statusbar
		Irssi::statusbar_items_redraw('proffer');
		return;
	}
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

	#update statusbar
	Irssi::statusbar_items_redraw('proffer');
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

	#update statusbar
	Irssi::statusbar_items_redraw('proffer');
}

sub irssi_queue_force {
	my ($data, $server, $item) = @_;

	if (($data =~ /^\d+\s*$/) && (exists $queue[$data-1])) {
		my ($item) = splice(@queue, $data-1, 1);
		$item->{'id'} =~ /^(.*), (.*)$/; my ($tag, $nick) = ($1, $2);
		irssi_send(Irssi::server_find_tag($tag), $nick, $item->{'pack'});
	}
	else { Irssi::print("Queue force error: $data isn't a packnumber."); }
}

sub irssi_queue_del {
	my ($data, $server, $item) = @_;

	if (($data =~ /^\d+\s*$/) && (exists $queue[$data-1])) {
		splice(@queue, $data-1, 1);
		Irssi::print("Removed queue number $data.");
  }
	else { Irssi::print("No such queue: $data."); }
}

sub irssi_queue_mov {
	my ($data, $server, $item) = @_;
	if ($data =~ /^(\d+)\s+(\d+)\s*$/) {
		my ($from, $to) = ($1, $2); $from--; $to--;
		if (exists $queue[$from] and exists $queue[$to]) {
			my $item = splice(@queue, $from, 1);
			my @end = splice(@queue, $to);
			push @queue, $item, @end;
			Irssi::print("Moved queue $from to $to.");
		}
		else { Irssi::print(sprintf("Could not move %d to %d: Index out of bounds.", ++$from, ++$to)); }
	}
	else { Irssi::print("Need two numbers to move from and to. Not: $data."); }
}

my $help_main = <<END;
\002proffer
proffer.pl v%vd is an irssi script to provide xdcc bot functionality created by pink_mist
(#shameimaru @ irc.rizon.net).

Website: http://github.com/pink-mist/proffer

\002Basic setup
 * /set proffer_channels <#channel1 ...>
 * /proffer_add <file|dir>

\002Settings
 * \002proffer_channels\002 <#channel1 ...>
   -- Set which channels to announce new packs in and monitor for `xdcc list´/`!list´.
 * \002proffer_restrict_send\002 <ON|OFF>
   -- Set to on if anyone wishing to use the bot \002has\002 to be in the specified channels.
 * \002proffer_list_deny\002 <message>
   -- If this is set to any value, xdcc lists will be denied, and the <message> will be sent
      instead. To unset this, use `\002/set -clear proffer_list_deny\002´.
 * \002proffer_list_file\002 <file>
   -- If this is set, the <file> will have an updated file list for the xdcc. This is useful
      for serving for example in pack #1, or through an http server. Just set
      \002proffer_list_deny\002 to point people in the direction of this file.
 * \002proffer_hide\002 <ON|OFF>
   -- Set to on to hide xdcc messages sent to you and responses you send. This will not hide
      file transfers.
 * \002proffer_queues\002 <num>
   -- Set how many queue-slots you want to provide.
 * \002proffer_queues_user\002 <num>
   -- Set the maximum number of queues a single user can have.
 * \002proffer_slots\002 <num>
   -- Set how many send slots you want to provide.
 * \002proffer_slots_user\002 <num>
   -- Set the maximum number of slots a single user can have.

\002Statusbar
You can also add a statusbar item which shows info on the status of the xdcc bot:
 * \002/statusbar window add proffer

\002See also
 /help ...
 proffer add        proffer add_ann    proffer announce   proffer del
 proffer list       proffer mov        proffer queue
END

my $help_add      = <<END;
\002proffer add

\002Syntax
 * /proffer add <file|dir>

Use this command to add a file to the xdcc file list. If you specify a directory,
every file in that directory and every subdirectory will be added except files and
subdirectories whose name starts with a period `.´.

\002Examples
 * /proffer add ~/my file.tar.gz
 * /proffer add /home/user/

\002See also
 /help ...
 proffer add_ann    proffer del        proffer mov
END

my $help_add_ann  = <<END;
\002proffer add_ann

\002Syntax
 * /proffer add_ann <file|dir>

This command does the same as `\002proffer add\002´ as well as announcing any added
pack in the channels set in `\002proffer_channels\002´:
  [\002added\002] <filename> - /msg <your_nick> xdcc send #<pack>

\002See also
 /help ...
 proffer add
END

my $help_announce = <<END;
\002proffer announce

\002Syntax
 * /proffer announce <num> <message>

This command announces the specified pack in the channels set in `\002proffer_channels\002´:
  [\002<message>\002] <filename> - /msg <your_nick> xdcc send #<num>
Use it if you want to call extra attention to a certain pack.

\002See also
 /help ...
 proffer add_ann
END

my $help_del      = <<END;
\002proffer del

\002Syntax
 * /proffer del <num>

Use this command to delete a pack from the file list. No actual file will be deleted.

\002See also
 /help ...
 proffer add
END

my $help_list     = <<END;
\002proffer list

\002Syntax
 * /proffer list

This displays the xdcc list.
END

my $help_mov      = <<END;
\002proffer mov

\002Syntax
 * /proffer mov <from> <to>

Use this command to move a pack in the xdcc list from number <from> to number <to>.
END

my $help_queue    = <<END;
\002proffer queue

\002Syntax
 * /proffer queue
 * /proffer queue del <num>
 * /proffer queue force <num>
 * /proffer queue send <num>

The first version of this command just displays the current queue, the others
manipulate it in some way.
 * `del´ deletes the specified queue without notifying the user.
 * `force´ and `send´ are synonyms that sends the specified queue to the user.

\002Examples
 * /proffer queue
 * /proffer queue del 3
 * /proffer queue force 8
END

sub irssi_help {
	my ($data) = @_;
	if ($data =~ /^proffer\b/i) {
		my $help = "No help for $data.";
		given ($data) {
			when (/^proffer\s*$/i)          { $help = sprintf($help_main, $VERSION); }
			when (/^proffer add\s*$/i)      { $help = $help_add; }
			when (/^proffer add_ann\s*$/i)  { $help = $help_add_ann; }
			when (/^proffer announce\s*$/i) { $help = $help_announce; }
			when (/^proffer del\s*$/i)      { $help = $help_del; }
			when (/^proffer list\s*$/i)     { $help = $help_list; }
			when (/^proffer mov\s*$/i)      { $help = $help_mov; }
			when (/^proffer queue\s*$/i)    { $help = $help_queue; }
		}
		Irssi::print($help);
		Irssi::signal_stop();
	}
}

sub irssi_completion {
	my ($strings, $window, $word, $linestart, $want_space) = @_;
	my $stop = 0;

	my @nums = (1 .. scalar(@files));
	given ($linestart) {
		when (/^\/proffer add(_ann)?$/i)     {
			$word =~ s/ /\\ /g;                  #escape spaces
		                                       #if filename is a directory, append /
		  push @$strings, map { if (-d $_) { "$_/" } else { "$_" } } glob("$word*");
		                           $$want_space = 0; $stop = 1; }
		when (/^\/proffer del$/i)            {
			if ($word =~ /^\d+$/) {
				my @end = splice(@nums, 0, $word-1); push @nums, @end; }
			$word = join(' ', @nums);            #for some reason we must *use* the @nums array, or irrsi will segfault
			push @$strings, @nums;   $$want_space = 0; $stop = 1; }
		when (/^\/proffer (mov|announce)$/i) {
			if ($word =~ /^\d+$/) {
				my @end = splice(@nums, 0, $word-1); push @nums, @end; }
			$word = join(' ', @nums);            #for some reason we must *use* the @nums array, or irrsi will segfault
			push @$strings, @nums;   $$want_space = 1; $stop = 1; }
		when (/^\/proffer mov (\d+)$/i)      {
			my $not = $1; @nums = grep { $_ != $not } @nums;
			if ($word =~ /^\d+$/) {
				my @end = splice(@nums, 0, $word > $not ? $word-2 : $word-1); push @nums, @end; }
			$word = join(' ', @nums);            #for some reason we must *use* the @nums array, or irrsi will segfault
			push @$strings, @nums;   $$want_space = 0; $stop = 1; }
		when (/^\/proffer announce \d+$/i)   {
			push @$strings, 'added'; $$want_space = 0; $stop = 1; }
		when (/^\/proffer queue (mov|del|force|send)$/i)          {
			@nums = (1 .. scalar(@queue));
			if ($word =~ /^\d+$/) {
				my @end = splice(@nums, 0, $word-1); push @nums, @end; }
			$word = join(' ', @nums);            #for some reason we must *use* the @nums array, or irrsi will segfault
			push @$strings, @nums;   $$want_space = 0; $stop = 1; }
		when (/^\/proffer queue mov (\d+)$/i)      {
			@nums = (1 .. scalar(@queue));
			my $not = $1; @nums = grep { $_ != $not } @nums;
			if ($word =~ /^\d+$/) {
				my @end = splice(@nums, 0, $word > $not ? $word-2 : $word-1); push @nums, @end; }
			$word = join(' ', @nums);            #for some reason we must *use* the @nums array, or irrsi will segfault
			push @$strings, @nums;   $$want_space = 0; $stop = 1; }
		#when (/^\/proffer list$/i)          { #placeholder for when we may change this
		#                          $$want_space = 0; $stop = 1; }
	}
	Irssi::signal_stop() if $stop;
}

sub irssi_statusbar {
	my ($sb_item, $get_size_only) = @_;
	my $statusbar = sprintf('F:%d S:%d/%d Q:%d/%d @%s/s',
			scalar(@files),                                                     #xdcc list length
			scalar(grep { $_->{'type'} eq 'SEND' } Irssi::Irc::dccs()),	$slots, #used slots, total slots
			scalar(@queue),	$queues,                                            #used queue, max queue
			current_speed());
	$sb_item->default_handler($get_size_only, '{sb $0-}', $statusbar, 1);
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



