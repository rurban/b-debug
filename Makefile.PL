use ExtUtils::MakeMaker;

WriteMakefile
  (
   NAME	           => "B::Debug",
   VERSION_FROM    => "Debug.pm",
   PREREQ_PM => {'B'         => 0,
		'Test::More' => 0},
   ($] >= 5.005 ?
    ('AUTHOR' => 'Malcolm Beattie <mbeattie@sable.ox.ac.uk>, Reini Urban <rurban@cpan.org>',
     'ABSTRACT' => 'print debug info about ops') : ()),
   ($ExtUtils::MakeMaker::VERSION gt '6.30' ?
    ('LICENSE'                => 'perl', ) : ()),
   ($ExtUtils::MakeMaker::VERSION gt '6.31' ?
    ('EXTRA_META'  => "recommends:\n" .
     "    B::Flags:                      0.02\n"
    ) : ()),
   # Part of core perl since 5.005005 (?)
   'INSTALLDIRS' => ( $] > 5.005005 ? "perl" : "site" ),
  );

print "fix pm_to_blib to install into ARCHLIB\n";
if ($^O eq 'MSWin32') {
  system($^X,'-pi.bak','-e"s|\(INST_LIB\)\\\\B\\\\Debug.pm|(INST_ARCHLIB)\\\\B\\\\Debug.pm|"','Makefile');
} else {
  system("$^X -pi.bak -e's|\\(INST_LIB\\)/B/Debug.pm|(INST_ARCHLIB)/B/Debug.pm|;' Makefile");
}

#package MY;
# pm_to_blib cannot be overridden
# Force installation into archlib to override the core version there
#sub pm_to_blib {
#  my $s = shift->SUPER::pm_to_blib(@_);
#  $s =~ s/\(INST_LIB\)/\(INST_ARCH\)/g;
#  $s;
#}
