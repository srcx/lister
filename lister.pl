#!/usr/bin/perl

# lister (c)2000-2011 Stepan Roh
#
# obhospodaruje jednoduche mailove konference

use Sys::Syslog qw(:DEFAULT setlogsock);

$debug = 1;

setlogsock ('unix');
openlog ('lister', 'cons,pid', 'user');

# maska konfiguracnich souboru - '%' se nahradi za jmeno konfery
$user_cfgmask = '/etc/mail/lister.conf.%';

# predmet zpravy pro administraci konfery
$user_control_subj = '*list-control';

# predmet zpravy pro subscribe_free
$user_subscribe_subj = '*list-subscribe';

# maximalni delka mailu (komplet) v bytech
$user_max_mail_size = 100000;

# maximalni delka mailu vzdy
$sys_max_mail_size = 1000000;

# umisteni sendmailu
$user_sendmail = '/usr/lib/sendmail';

sub print_log ($) {
  my ($m) = @_;

  if ($logfile) {
    if ($m =~ s/!//) {
      open (LOG, ">>$logfile") || syslog ('err', "Error opening log %s : $!\n", $logfile);
    } else {
      open (LOG, ">>$logfile") || die "Error opening log $logfile : $!\n";
    }
    print LOG '[', scalar localtime, "] lister: $m";
    close (LOG);
  }
}

eval {

  if ($#ARGV < 1) {
    die "Too few command-line arguments\n";
  }
  
  $list_name = $ARGV[0];
  $full_list_name = $ARGV[1];

  if ($debug) { syslog ('debug', 'list name is %s', $list_name); }

  $subscribe_free = $send_free = $sender_nosend = 0;
  $list_all = 1;
  $subject_prefix = '';

  ($cfgfile = $user_cfgmask) =~ s/%/$list_name/g;
  open (CFG, $cfgfile) || die "Error opening $cfgfile : $!\n";

  # nacteni konfigurace
  while (<CFG>) {
    if (/^\s*$/ || /^#/) { next; }
    chomp ($_);
    ($class, $value) = split (/\s+/, $_, 2);
    if ($class eq 'listfile') {
      $listfile = $value;
    } elsif ($class eq 'archive') {
      $cfg_archive = $value;		# soubor s archivem
    } elsif ($class eq 'msg_help') {
      $cfg_msg_help = $value;		# vzorovy mail s helpem
    } elsif ($class eq 'msg_welcome') {
      $cfg_msg_welcome = $value;	# vzorovy mail na uvitanou (jenom pro receivers, senders nedostanou nic)
    } elsif ($class eq 'msg_kickoff') {
      $cfg_msg_kickoff = $value;	# vzorovy mail na vykopnuti
    } elsif ($class eq 'msg_notify') {
      $cfg_msg_notify = $value;		# vzorovy mail na zmenu
    } elsif ($class eq 'subscribe_free') {
      $subscribe_free = $value;		# kazdy se muze prihlasit sam?
    } elsif ($class eq 'send_free') {
      $send_free = $value;		# kdokoliv muze poslat mail?
    } elsif ($class eq 'sender_nosend') {
      $sender_nosend = $value;		# neposilat mail odesilateli?
    } elsif ($class eq 'logfile') {
      $logfile = $value;		# soubor s logy
    } elsif ($class eq 'list_all') {
      $list_all = $value;		# muze kazdy videt v list vsechny?
    } elsif ($class eq 'subject_prefix') {
      $subject_prefix = $value;
    } elsif ($class eq 'max_mail_size') {
      if (($value >= 0) && ($value <= $sys_max_mail_size)) {
        $user_max_mail_size = $value;	# max. velikost mailu
      }
    } elsif ($class eq 'filter') {
      push (@cfg_filters, $value);	# filtry
    } else {
      die "Unknown class $class in configuration $cfgfile\n";
    }
  }
  
  close (CFG);
  
  if (!defined $listfile) {
    die "Configuration file $cfgfile is missing required option listfile\n";
  }
  
  open (LIST, "+<$listfile") || die "Error opening $listfile : $!\n";
  flock (LIST, 2);
  seek (LIST, 0, 0);

  # nacteni seznamu
  while (<LIST>) {
    if (/^\s*$/ || /^#/) { next; }
    chomp ($_);
    ($class, $value) = split (/\s+/, $_, 2);
    $value = lc ($value);
    if ($class eq 'sender') {
      $list{$value}{'S'} = 1;		# muze posilat
    } elsif ($class eq 'receiver') {
      $list{$value}{'R'} = 1;		# obdrzi kazdou spravu
    } elsif ($class eq 'admin') {
      $list{$value}{'A'} = 1;		# muze administrovat
    } else {
      die "Unknown class $class in list file $listfile\n";
    }
  }
  
  # nacteni mailu do pameti
  $mail_from = $mail_to = $mail_subj = '';
  $mail_len = 0; $is_body = 0;
  @mail_hdrs = ();
  $last_header = '';
  while (<STDIN>) {
    $mail_len += length ($_);
    if ($mail_len > $user_max_mail_size) {
      die "Mail is longer than $user_max_mail_size bytes\n";
    }
    if ($is_body) {
      push (@mail_body, $_);
    } else {
      push (@mail_header, $_);
      if (/^\s*$/) {
        $is_body = 1;
        next;
      }
      if (/^From:\s*(.*?)\s*$/) {
        $mail_from = $1;
        $last_header = 'from';
      } elsif (/^To:\s*(.*?)\s*$/) {
        $mail_to = $1;
        $last_header = 'to';
      } elsif (/^Subject:\s*(.*?)\s*$/) {
        $mail_subj = $1;
        $last_header = 'subj';
      } elsif (/^Reply-To:/) {
        # ignored
        $last_header = '';
      } elsif ((/^(\s+\S.*)\s*$/) && ($last_header ne '')) {
        ${"mail_$last_header"} .= $1;
      } else {
        push (@mail_hdrs, $_);
        $last_header = '';
      }
    }
  }

  if ($debug) { syslog ('debug', 'received mail From: %s To: %s Subject: %s', $mail_from, $mail_to, $mail_subj); }

  if ($mail_from =~ /MAILER-DAEMON/) {
    die "Attempt to send returned mail from $mail_from\n";
  }

  if ($mail_from =~ /<(.*)>/) {
    $sender = $1;
  } else {
    $sender = $mail_from;
  }
  $sender =~ tr/A-Za-z0-9@_.-//dc;
#  if ($sender =~ /^(.*?)@(.*)$/) {
#    ($sender_user, $sender_addr) = ($1, $2);
#    $sender = $sender_user . '@' . lc ($sender_addr);
#  }
  $sender = lc ($sender);
  
  print_log ("received mail (From: $mail_from, Subject: $mail_subj)\n");
  
  sub send_help ($) {
    my ($sender) = @_;
    
    if ($debug) { syslog ('debug', 'sending help to %s', $sender); }
    open (MAIL, "|$user_sendmail $sender") || die "Error invoking sendmail : $!\n";
    print MAIL <<END;
To: $mail_from
From: $full_list_name
Reply-To: $full_list_name
Subject: $subject_prefix $list_name help
Precedence: list
Mailing-List: $full_list_name

END
    if ($cfg_msg_help) {
      open (HELP, $cfg_msg_help) || die "Error opening $cfg_msg_help : $!\n";
      while (<HELP>) { print MAIL; }
      close (HELP);
    } else {
      print MAIL "Sorry, no help available\n";
    }
    print MAIL <<END;
.
END
    close (MAIL);
  }
  
  sub send_welcome ($) {
    my ($mail) = @_;
    
    if ($debug) { syslog ('debug', 'sending welcome to %s', $mail); }
    open (MAIL, "|$user_sendmail $mail") || die "Error invoking sendmail : $!\n";
    print MAIL <<END;
To: $mail
From: $full_list_name
Reply-To: $full_list_name
Subject: $subject_prefix Welcome to $list_name
Precedence: list
Mailing-List: $full_list_name

END
    if ($cfg_msg_welcome) {
      open (HELP, $cfg_msg_welcome) || die "Error opening $cfg_msg_welcome : $!\n";
      while (<HELP>) { print MAIL; }
      close (HELP);
    } else {
      print MAIL "Welcome to the list $list_name\n";
    }
    print MAIL <<END;
.
END
    close (MAIL);
  }
  
  sub send_kickoff ($) {
    my ($mail) = @_;
    
    if ($debug) { syslog ('debug', 'sending kickoff to %s', $mail); }
    open (MAIL, "|$user_sendmail $mail") || die "Error invoking sendmail : $!\n";
    print MAIL <<END;
To: $mail
From: $full_list_name
Reply-To: $full_list_name
Subject: $subject_prefix Leaving $list_name
Precedence: list
Mailing-List: $full_list_name

END
    if ($cfg_msg_kickoff) {
      open (HELP, $cfg_msg_kickoff) || die "Error opening $cfg_msg_kickoff : $!\n";
      while (<HELP>) { print MAIL; }
      close (HELP);
    } else {
      print MAIL "You're no longer member of the list $list_name\n";
    }
    print MAIL <<END;
.
END
    close (MAIL);
  }
  
  sub send_notify ($) {
    my ($mail) = @_;
    
    if ($debug) { syslog ('debug', 'sending notify to %s', $mail); }
    open (MAIL, "|$user_sendmail $mail") || die "Error invoking sendmail : $!\n";
    print MAIL <<END;
To: $mail
From: $full_list_name
Reply-To: $full_list_name
Subject: $subject_prefix $list_name notification
Precedence: list
Mailing-List: $full_list_name

END
    if ($cfg_msg_notify) {
      open (HELP, $cfg_msg_notify) || die "Error opening $cfg_msg_notify : $!\n";
      while (<HELP>) { print MAIL; }
      close (HELP);
    } else {
      print MAIL "Your user's information in the list $list_name has changed\n";
    }
    print MAIL <<END;
.
END
    close (MAIL);
  }
  
  sub send_list ($$$) {
    my ($sender, $all, $mail) = @_;
    
    sub print_user ($) {
      my ($u) = @_;
      
      if ($list{$u}{'S'}) {
        print MAIL "S";
      } else {
        print MAIL ".";
      }
      if ($list{$u}{'R'}) {
        print MAIL "R";
      } else {
        print MAIL ".";
      }
      if ($list{$u}{'A'}) {
        print MAIL "A";
      } else {
        print MAIL ".";
      }
      print MAIL " $u\n";
    }
    
    if ($debug) { syslog ('debug', 'sending list to %s', $sender); }
    open (MAIL, "|$user_sendmail $sender") || die "Error invoking sendmail : $!\n";
    print MAIL <<END;
To: $mail_from
From: $full_list_name
Reply-To: $full_list_name
Subject: $subject_prefix $list_name users list
Precedence: list
Mailing-List: $full_list_name

END
    if ($mail) {
      print_user ($mail);
    } elsif ($all) {
      foreach $user (keys %list) {
        print_user ($user);
      }
    } else {
      print_user ($sender);
    }
    print MAIL <<END;

Rights: S = Sender, R = Receiver, A = Administrator
.
END
    close (MAIL);
  }
  
  if ($mail_subj eq $user_subscribe_subj) {
    if (!$subscribe_free) {
      die "$sender attempted to subscribe to non-free list\n";
    }
    
    print_log ("subscribing $sender\n");
    
    $list{$sender}{'S'} = 1;
    $list{$sender}{'R'} = 1;
    send_welcome ($sender);
    $changed_list = 1;
    
    goto CFG_WRITE;

  } elsif ($mail_subj eq $user_control_subj) {
    $changed_list = 0;
    if ($debug) { syslog ('debug', 'list control mode'); }
    foreach $line (@mail_body) {
      if (($line =~ /^\s*$/) || ($line =~ /^#/)) { next; }
      ($cmd, $arg) = split (/\s+/, $line, 2);
      chomp ($cmd); chomp ($arg);
      $arg =~ tr/A-Za-z0-9@_.-//dc;
      if ($debug) {
        if ($arg) { syslog ('debug', 'command %s arg %s', $cmd, $arg); }
        else { syslog ('debug', 'command %s', $cmd); }
      }
      print_log ("$sender sent command $cmd $arg\n");
      if ($cmd eq 'help') {			# napoveda
        send_help ($sender);
      } elsif ($cmd eq 'list') {		# seznam konferujicich
	if (!exists $list{$sender}) {
          die "$sender is not authorised for getting users list\n";
        }
        if ($arg) {
          send_list ($sender, 1, $arg);
        } else {
          send_list ($sender, $list_all, '');
        }
      } elsif ($cmd eq 'del') {
        if ($arg && !$list{$sender}{'A'}) {
          die "$sender is not authorised for deleting $arg\n";
        }
        if (!$arg) { $arg = $sender; }
        undef ($list{$arg});
        send_kickoff ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'add') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for adding $arg\n";
        }
        $list{$arg}{'S'} = 1;
        $list{$arg}{'R'} = 1;
        send_welcome ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'add_sender') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for adding $arg as sender\n";
        }
        $list{$arg}{'S'} = 1;
        send_notify ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'add_receiver') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for adding $arg as receiver\n";
        }
        $list{$arg}{'R'} = 1;
        send_notify ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'add_admin') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for adding $arg as administrator\n";
        }
        $list{$arg}{'A'} = 1;
        send_notify ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'del_sender') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for deleting $arg from senders\n";
        }
        $list{$arg}{'S'} = 0;
        send_notify ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'del_receiver') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for deleting $arg from receivers\n";
        }
        $list{$arg}{'R'} = 0;
        send_notify ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'del_admin') {
        if (!$arg || !$list{$sender}{'A'}) {
          die "$sender is not authorised for deleting $arg from administrators\n";
        }
        $list{$arg}{'A'} = 0;
        send_notify ($arg);
        $changed_list = 1;
      } elsif ($cmd eq 'replace') {
        my ($arg1, $arg2) = split (/\s+/, $arg);
        if (!$arg1 || !$arg2 || !$list{$sender}{'A'}) {
          die "$sender is not authorised for replacing $arg1 with $arg2\n";
        }
        $list{$arg2} = $list{$arg1};
        undef ($list{$arg1});
        send_kickoff ($arg1);
        send_welcome ($arg2);
        $changed_list = 1;
      } else {
        die "Unknown command $cmd\n";
      }
    }
    
    CFG_WRITE:
    # ulozeni zmeneho seznamu
    if ($changed_list) {
      seek (LIST, 0, 0);
      
      foreach $i (keys %list) {
        if ($list{$i}{'S'}) {
          print LIST "sender $i\n";
        }
        if ($list{$i}{'R'}) {
          print LIST "receiver $i\n";
        }
        if ($list{$i}{'A'}) {
          print LIST "admin $i\n";
        }
      }
    }
    
    flock (LIST, 8);
    close (LIST);

  } else {
  
    # neni treba zdrzovat ostatni
    flock (LIST, 8);
    close (LIST);

    if (!$send_free && !$list{$sender}{'S'}) {
      die "$sender is not authorized for sending to the list $list_name\n";
    }
    
    # receivers
    @mail_adr = ();
    foreach $mail (keys %list) {
      next if (!$list{$mail}{'R'});
      $mail =~ tr/A-Za-z0-9@_.-//dc;
      if ($sender_nosend && ($mail eq $sender)) {
        if ($debug) { syslog ('debug', 'did not send message to sender %s', $mail); }
        next;
      }
      if ($debug) { syslog ('debug', 'sending message to %s', $mail); }
      unshift (@mail_adr, $mail);
    }
    $mail = join (' ', @mail_adr);
    open (MAIL, "|$user_sendmail $mail") || die "Error invoking sendmail : $!\n";
    print MAIL join ('', @mail_hdrs);
    print MAIL <<END;
To: $mail_to
From: $mail_from
Reply-To: $full_list_name
Subject: $subject_prefix $mail_subj
Precedence: list
Mailing-List: $full_list_name

END
    foreach $line (@mail_body) {
      print MAIL $line;
    }
    print MAIL <<END;
.
END
    close (MAIL);
    
    # archive
    if ($cfg_archive) {
      if ($debug) { syslog ('debug', 'archiving message to %s', $cfg_archive); }
      open (ARC, ">>$cfg_archive") || die "Error opening $cfg_archive : $!\n";
      flock (ARC, 2);
      seek (ARC, 0, 2);
      foreach $line (@mail_header) {
        print ARC $line;
      }
      foreach $line (@mail_body) {
        print ARC $line;
      }
      print ARC "\n";
      flock (ARC, 8);
      close (ARC);
    }
    
    # filters
    open (SAVEOUT, ">&STDOUT");
    open (SAVEERR, ">&STDERR");
    if ($logfile) {
      open (STDOUT, ">>$logfile");
    } else {
      open (STDERR, ">/dev/null");
    }
    open (STDERR, ">&STDOUT");
    foreach $filter (@cfg_filters) {
      if ($debug) { syslog ('debug', 'filtering message through \'%s\'', $filter); }
      open (FILTER, "|$filter") || die "Failed to execute filter '$filter' : $!\n";
      foreach $line (@mail_header) {
        print FILTER $line;
      }
      foreach $line (@mail_body) {
        print FILTER $line;
      }
      close (FILTER);
      my $rc = $?;
      if ($rc == 0xff00) {
        print_log ("Failed to execute filter '$filter' : $!\n");
      } elsif ($rc >>= 8) {
        print_log ("Filter '$filter' returned error code $rc\n");
      }
      if ($debug) { syslog ('debug', 'filter \'%s\' ended', $filter); }
    }
    open (STDOUT, ">&SAVEOUT");
    open (STDERR, ">&SAVEERR");
  }
  
};

if ($@) {
  $m = $@;
  syslog ('err', '%s', $m);
  print_log ('!'.$m);
}

closelog ();

1;
