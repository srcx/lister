# lister

## Running

`./lister.pl <list_name> <full_list_name>`

`list_name` is a short name for mailing list (mail alias - e.g. mlist)
`full_list_name` is list_name with domain (e.g. mlist@domain.com)

Mail is expected on standard input. How it is processed is defined in
configuration file `/etc/mail/lister.conf.<list_name>` (can be changed on top
of lister.pl, like any other system setting).

## Configuration file format

Except for empty lines and comment lines starting with '#', it has lines in
the format:

archive filename
    processed mails are appended to this file
msg_help filename
    text file with help
msg_welcome filename
    text file with new subscriber invitation
msg_kickoff filename
    text file with kickoff user message
msg_notify filename
    text file with user status changed message
subscribe_free 0(default)|1
    1 if anyone can subscribe themself
send_free 0(default)|1
    1 if anyone can send a mail to the list
sender_nosend 0(default)|1
    1 if sender does not want his own mail to be sent to him
list_all 0|1(default)
    1 if command list should list all subscribers
listfile filename
    file with list of users
logfile filename
    log file
filter command with args
    this command will be run with mail on standard input, standard output
    and standard error output will be redirected to logfile
max_mail_size size
    max mail size in bytes, default is 100000, hardcoded max is 1000000
subject_prefix text
    prefix of the subject of all sent mails

The only required item is listfile. If archive is not specified mails are
not archived, if logfile is not specified, no logging is done (only to
syslog), if some of the msg_ is not specified, then brief English message is
used. There can be multiple filters and they are executed in the order in
which they are written.

Then listfile must be created with the lines in the format:

sender mail
    address which can send mail
receiver mail
    address which will receive mail
admin mail
    address of the administrator

Listfile contents can be changed by administrator by control mails. One
address can appear on multiple lines.

User subscription if subscribe_free is permitted is done by sending mail to
the mailing list address with subject '*list-subscribe' (w/o apostrophes).

If mail with subject '*list-control' (w/o apostrophes) is sent to the
mailing list address all commands enclosed in the mail body are executed.

- commands which don't require any rights:

  help
      returns to sender mail with help (msg_help) 
  del
      deletes sender and sends him msg_kickoff 

- commands which require sender, receiver or admin:

  list
      returns to sender mail with list of all participants, if list_all is
      not set only sender rights are included
  list mail
      returns to sender mail with rights of given participant

- commands which require admin:

  add mail
      adds mail as sender and receiver and sends msg_welcome 
  add_sender mail
      adds mail as sender and sends msg_notify 
  add_receiver mail
      adds mail as receiver and sends msg_notify 
  add_admin mail
      adds mail as admin and sends msg_notify 
  del mail
      removes mail from everywhere and sends msg_kickoff 
  del_sender mail
      removes mail as sender and sends msg_notify 
  del_receiver mail
      removes mail as receiver and sends msg_notify 
  del_admin mail
      removes mail as admin and sends msg_notify 
  replace old_mail new_mail
      replaces old mail with new mail, old one gets msg_kickoff, new one
      msg_welcome
