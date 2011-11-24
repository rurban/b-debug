package B::Debug;

# Note: Same as for B::Concise we need to keep track of how many
# use declarations/BEGIN blocks this module uses, so we can avoid
# printing them when user asks for the BEGIN blocks in her program.
# Update the comments and the count in concise_specials if you add
# or delete one. The -MO=Debug counts as use #1.

our $VERSION = '1.99_01';

use strict; # use #2
require 5.006;
# use #3
use B qw(peekop class walkoptree walkoptree_exec
         main_start main_root cstring sv_undef SVf_NOK SVf_IOK);
use Config;
my (@optype, @specialsv_name);
require B;
if ($] < 5.009) {
  require B::Asmdata;
  B::Asmdata->import (qw(@optype @specialsv_name));
} else {
  B->import (qw(@optype @specialsv_name));
}

if ($] < 5.006002) {
  eval q|sub B::GV::SAFENAME {
    my $name = (shift())->NAME;
    # The regex below corresponds to the isCONTROLVAR macro from toke.c
    $name =~ s/^([\cA-\cZ\c\\c[\c]\c?\c_\c^])/"^".chr(64 ^ ord($1))/e;
    return $name;
  }|;
}

# options from B::Concise
my $order = "basic";	# how optree is walked & printed: basic, exec, tree
my $base = 36;		# how <sequence#> is displayed
my $big_endian = 1;	# more <sequence#> display
my $tree_style = 0;	# tree-order details
my $banner = 1;		# print banner before optree is traversed
my $do_main = 0;	# force printing of main routine
my $show_src;		# show source code
my @render_packs; 	# collect -stash=<packages>
my %sequence_num;
my $seq_max = 1;
my %labels;
my $lastnext;		# remembers op-chain, used to insert gotos

my ($have_B_Flags, $have_B_Flags_extra);
if (!$ENV{PERL_CORE}){ # avoid CORE test crashes
  eval { require B::Flags and $have_B_Flags++ };
  $have_B_Flags_extra++ if $have_B_Flags and $B::Flags::VERSION gt '0.03';
}
my %done_gv;

# from B::Concise
my $chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
sub base_n {
    my $x = shift;
    return "-" . base_n(-$x) if $x < 0;
    my $str = "";
    do { $str .= substr($chars, $x % $base, 1) } while $x = int($x / $base);
    $str = reverse $str if $big_endian;
    return $str;
}

sub reset_sequence {
    # reset the sequence
    %sequence_num = ();
    $seq_max = 1;
    $lastnext = 0;
}

sub seq {
    my($op) = @_;
    return "-" if not exists $sequence_num{$$op};
    return base_n($sequence_num{$$op});
}

# The structure of this routine is purposely modeled after op.c's peep()
sub sequence {
    my($op) = @_;
    my $oldop = 0;
    return if class($op) eq "NULL" or exists $sequence_num{$$op};
    for (; $$op; $op = $op->next) {
	last if exists $sequence_num{$$op};
	my $name = $op->name;
	if ($name =~ /^(null|scalar|lineseq|scope)$/) {
	    next if $oldop and $ {$op->next};
	} else {
	    $sequence_num{$$op} = $seq_max++;
	    if (class($op) eq "LOGOP") {
		my $other = $op->other;
		$other = $other->next while $other->name eq "null";
		sequence($other);
	    } elsif (class($op) eq "LOOP") {
		my $redoop = $op->redoop;
		$redoop = $redoop->next while $redoop->name eq "null";
		sequence($redoop);
		my $nextop = $op->nextop;
		$nextop = $nextop->next while $nextop->name eq "null";
		sequence($nextop);
		my $lastop = $op->lastop;
		$lastop = $lastop->next while $lastop->name eq "null";
		sequence($lastop);
	    } elsif ($name eq "subst" and $ {$op->pmreplstart}) {
		my $replstart = $op->pmreplstart;
		$replstart = $replstart->next while $replstart->name eq "null";
		sequence($replstart);
	    }
	}
	$oldop = $op;
    }
}

# output handle, used with all output printing
our $walkHandle;	# public for your convenience
BEGIN { $walkHandle = \*STDOUT }

sub walk_output { # updates $walkHandle
    my $handle = shift;
    return $walkHandle unless $handle; # allow use as accessor

    if (ref $handle eq 'SCALAR') {
	require Config;
	die "no perlio in this build, can't call walk_output (\\\$scalar)\n"
	    unless $Config::Config{useperlio};
	# in 5.8+, open(FILEHANDLE,MODE,REFERENCE) writes to string
	open my $tmp, '>', $handle;	# but cant re-set existing STDOUT
	$walkHandle = $tmp;		# so use my $tmp as intermediate var
	return $walkHandle;
    }
    my $iotype = ref $handle;
    die "expecting argument/object that can print\n"
	unless $iotype eq 'GLOB' or $iotype and $handle->can('print');
    $walkHandle = $handle;
}

# back to old B::Debug
sub _printop {
  my $op = shift;
  my $addr = ${$op} ? $op->ppaddr : '';
  $addr =~ s/^PL_ppaddr// if $addr;
  return sprintf "0x%08x %6s %s", ${$op}, ${$op} ? class($op) : '', $addr;
}

sub B::OP::debug {
    my ($op) = @_;
    printf <<'EOT', class($op), $$op, _printop($op), _printop($op->next), _printop($op->sibling), $op->targ, $op->type, $op->name;
%s (0x%lx)
	op_ppaddr	%s
	op_next		%s
	op_sibling	%s
	op_targ		%d
	op_type		%d	%s
EOT
    if ($] > 5.009) {
	printf <<'EOT', $op->opt;
	op_opt		%d
EOT
    } else {
	printf <<'EOT', $op->seq;
	op_seq		%d
EOT
    }
    if ($have_B_Flags) {
        printf <<'EOT', $op->flags, $op->flagspv, $op->private, $op->privatepv;
	op_flags	%d	%s
	op_private	%d	%s
EOT
    } else {
        printf <<'EOT', $op->flags, $op->private;
	op_flags	%d
	op_private	%d
EOT
    }
}

sub B::UNOP::debug {
    my ($op) = @_;
    $op->B::OP::debug();
    printf "\top_first\t%s\n", _printop($op->first);
}

sub B::BINOP::debug {
    my ($op) = @_;
    $op->B::UNOP::debug();
    printf "\top_last \t%s\n", _printop($op->last);
}

sub B::LOOP::debug {
    my ($op) = @_;
    $op->B::BINOP::debug();
    printf <<'EOT', _printop($op->redoop), _printop($op->nextop), _printop($op->lastop);
	op_redoop	%s
	op_nextop	%s
	op_lastop	%s
EOT
}

sub B::LOGOP::debug {
    my ($op) = @_;
    $op->B::UNOP::debug();
    printf "\top_other\t%s\n", _printop($op->other);
}

sub B::LISTOP::debug {
    my ($op) = @_;
    $op->B::BINOP::debug();
    printf "\top_children\t%d\n", $op->children;
}

sub B::PMOP::debug {
    my ($op) = @_;
    $op->B::LISTOP::debug();
    printf "\top_pmreplroot\t0x%x\n", $] < 5.008 ? ${$op->pmreplroot} : $op->pmreplroot;
    printf "\top_pmreplstart\t0x%x\n", ${$op->pmreplstart};
    printf "\top_pmnext\t0x%x\n", ${$op->pmnext} if $] < 5.009005;
    if ($Config{'useithreads'}) {
      printf "\top_pmstashpv\t%s\n", cstring($op->pmstashpv);
      printf "\top_pmoffset\t%d\n", $op->pmoffset;
    } else {
      printf "\top_pmstash\t%s\n", cstring($op->pmstash);
    }
    printf "\top_precomp\t%s\n", cstring($op->precomp);
    printf "\top_pmflags\t0x%x\n", $op->pmflags;
    printf "\top_reflags\t0x%x\n", $op->reflags if $] >= 5.009;
    printf "\top_pmpermflags\t0x%x\n", $op->pmpermflags if $] < 5.009;
    printf "\top_pmdynflags\t0x%x\n", $op->pmdynflags if $] < 5.009;
    $op->pmreplroot->debug if $] < 5.008;
}

sub B::COP::debug {
    my ($op) = @_;
    $op->B::OP::debug();
    my $warnings = ref $op->warnings ? ${$op->warnings} : 0;
    printf <<'EOT', $op->label, $op->stashpv, $op->file, $op->cop_seq, $op->arybase, $op->line, $warnings;
	cop_label	"%s"
	cop_stashpv	"%s"
	cop_file	"%s"
	cop_seq		%d
	cop_arybase	%d
	cop_line	%d
	cop_warnings	0x%x
EOT
  if ($] > 5.008 and $] < 5.011) {
    my $cop_io = class($op->io) eq 'SPECIAL' ? '' : $op->io->as_string;
    printf("	cop_io		%s\n", cstring($cop_io));
  }
}

sub B::SVOP::debug {
    my ($op) = @_;
    $op->B::OP::debug();
    printf "\top_sv\t\t0x%x\n", ${$op->sv};
    $op->sv->debug;
}

sub B::PVOP::debug {
    my ($op) = @_;
    $op->B::OP::debug();
    printf "\top_pv\t\t%s\n", cstring($op->pv);
}

sub B::PADOP::debug {
    my ($op) = @_;
    $op->B::OP::debug();
    printf "\top_padix\t%ld\n", $op->padix;
}

sub B::NULL::debug {
    my ($sv) = @_;
    if ($$sv == ${sv_undef()}) {
	print "&sv_undef\n";
    } else {
	printf "NULL (0x%x)\n", $$sv;
    }
}

sub B::SV::debug {
    my ($sv) = @_;
    if (!$$sv) {
	print class($sv), " = NULL\n";
	return;
    }
    printf <<'EOT', class($sv), $$sv, $sv->REFCNT;
%s (0x%x)
	REFCNT		%d
	FLAGS		0x%x
EOT
    printf "\tFLAGS\t\t0x%x", $sv->FLAGS;
    if ($have_B_Flags) {
      printf "\t%s", $have_B_Flags_extra ? $sv->flagspv(0) : $sv->flagspv;
    }
    print "\n";
}

sub B::RV::debug {
    my ($rv) = @_;
    B::SV::debug($rv);
    printf <<'EOT', ${$rv->RV};
	RV		0x%x
EOT
    $rv->RV->debug;
}

sub B::PV::debug {
    my ($sv) = @_;
    $sv->B::SV::debug();
    my $pv = $sv->PV();
    printf <<'EOT', cstring($pv), length($pv);
	xpv_pv		%s
	xpv_cur		%d
EOT
}

sub B::IV::debug {
    my ($sv) = @_;
    $sv->B::SV::debug();
    printf "\txiv_iv\t\t%d\n", $sv->IV if $sv->FLAGS & SVf_IOK;
}

sub B::NV::debug {
    my ($sv) = @_;
    $sv->B::IV::debug();
    printf "\txnv_nv\t\t%s\n", $sv->NV if $sv->FLAGS & SVf_NOK;
}

sub B::PVIV::debug {
    my ($sv) = @_;
    $sv->B::PV::debug();
    printf "\txiv_iv\t\t%d\n", $sv->IV if $sv->FLAGS & SVf_IOK;
}

sub B::PVNV::debug {
    my ($sv) = @_;
    $sv->B::PVIV::debug();
    printf "\txnv_nv\t\t%s\n", $sv->NV if $sv->FLAGS & SVf_NOK;
}

sub B::PVLV::debug {
    my ($sv) = @_;
    $sv->B::PVNV::debug();
    printf "\txlv_targoff\t%d\n", $sv->TARGOFF;
    printf "\txlv_targlen\t%u\n", $sv->TARGLEN;
    printf "\txlv_type\t%s\n", cstring(chr($sv->TYPE));
}

sub B::BM::debug {
    my ($sv) = @_;
    $sv->B::PVNV::debug();
    printf "\txbm_useful\t%d\n", $sv->USEFUL;
    printf "\txbm_previous\t%u\n", $sv->PREVIOUS;
    printf "\txbm_rare\t%s\n", cstring(chr($sv->RARE));
}

sub B::CV::debug {
    my ($sv) = @_;
    $sv->B::PVNV::debug();
    my ($stash) = $sv->STASH;
    my ($start) = $sv->START;
    my ($root)  = $sv->ROOT;
    my ($padlist) = $sv->PADLIST;
    my ($file) = $sv->FILE;
    my ($gv) = $sv->GV;
    printf <<'EOT', $$stash, $$start, $$root, $$gv, $file, $sv->DEPTH, $padlist, ${$sv->OUTSIDE};
	STASH		0x%x
	START		0x%x
	ROOT		0x%x
	GV		0x%x
	FILE		%s
	DEPTH		%d
	PADLIST		0x%x
	OUTSIDE		0x%x
EOT
    printf("\tOUTSIDE_SEQ\t%d\n", , $sv->OUTSIDE_SEQ) if $] > 5.007;
    if ($have_B_Flags) {
      my $SVt_PVCV = $] < 5.010 ? 12 : 13;
      printf("\tCvFLAGS\t0x%x\t%s\n", $sv->CvFLAGS,
	     $have_B_Flags_extra ? $sv->flagspv($SVt_PVCV) : $sv->flagspv);
    } else {
      printf("\tCvFLAGS\t0x%x\n", $sv->CvFLAGS);
    }
    $start->debug if $start;
    $root->debug if $root;
    $gv->debug if $gv;
    $padlist->debug if $padlist;
}

sub B::AV::debug {
    my ($av) = @_;
    $av->B::SV::debug;
    # tied arrays may leave out FETCHSIZE
    my (@array) = eval { $av->ARRAY; };
    print "\tARRAY\t\t(", join(", ", map("0x" . $$_, @array)), ")\n";
    my $fill = eval { scalar(@array) };
    if ($Config{'useithreads'}) {
      printf <<'EOT', $fill, $av->MAX, $av->OFF;
	FILL		%d
	MAX		%d
	OFF		%d
EOT
    } else {
      printf <<'EOT', $fill, $av->MAX;
	FILL		%d
	MAX		%d
EOT
    }
    if ($] < 5.009) {
      if ($have_B_Flags) {
	printf("\tAvFLAGS\t0x%x\t%s\n", $av->AvFLAGS,
	       $have_B_Flags_extra ? $av->flagspv(10) : $av->flagspv);
      } else {
	printf("\tAvFLAGS\t0x%x\n", $av->AvFLAGS);
      }
    }
}

sub B::GV::debug {
    my ($gv) = @_;
    if ($done_gv{$$gv}++) {
	printf "GV %s::%s\n", $gv->STASH->NAME, $gv->SAFENAME;
	return;
    }
    my $sv = $gv->SV;
    my $av = $gv->AV;
    my $cv = $gv->CV;
    $gv->B::SV::debug;
    printf <<'EOT', $gv->SAFENAME, $gv->STASH->NAME, $gv->STASH, $$sv, $gv->GvREFCNT, $gv->FORM, $$av, ${$gv->HV}, ${$gv->EGV}, $$cv, $gv->CVGEN, $gv->LINE, $gv->FILE, $gv->GvFLAGS;
	NAME		%s
	STASH		%s (0x%x)
	SV		0x%x
	GvREFCNT	%d
	FORM		0x%x
	AV		0x%x
	HV		0x%x
	EGV		0x%x
	CV		0x%x
	CVGEN		%d
	LINE		%d
	FILE		%s
EOT
    if ($have_B_Flags) {
      my $SVt_PVGV = $] < 5.010 ? 13 : 9;
      printf("\tGvFLAGS\t0x%x\t%s\n", $gv->GvFLAGS,
	     $have_B_Flags_extra ? $gv->flagspv($SVt_PVGV) : $gv->flagspv);
    } else {
      printf("\tGvFLAGS\t0x%x\n", $gv->GvFLAGS);
    }
    $sv->debug if $sv;
    $av->debug if $av;
    $cv->debug if $cv;
}

sub B::SPECIAL::debug {
    my $sv = shift;
    my $i = ref $sv ? $$sv : 0;
    print exists $specialsv_name[$i] ? $specialsv_name[$i] : "", "\n";
}

# taken from B::Concise
sub compileOpts {
    # set rendering state from options and args
    my (@options,@args);
    if (@_) {
	@options = grep(/^-/, @_);
	@args = grep(!/^-/, @_);
    }
    for my $o (@options) {
	# mode/order
	if ($o eq "-basic") {
	    $order = "basic";
	} elsif ($o eq "-exec") {
	    $order = "exec";
	} elsif ($o eq "-tree") {
	    $order = "tree";
	}
	# tree-specific
	elsif ($o eq "-compact") {
	    $tree_style |= 1;
	} elsif ($o eq "-loose") {
	    $tree_style &= ~1;
	} elsif ($o eq "-vt") {
	    $tree_style |= 2;
	} elsif ($o eq "-ascii") {
	    $tree_style &= ~2;
	}
	# sequence numbering
	elsif ($o =~ /^-base(\d+)$/) {
	    $base = $1;
	} elsif ($o eq "-bigendian") {
	    $big_endian = 1;
	} elsif ($o eq "-littleendian") {
	    $big_endian = 0;
	}
	# miscellaneous, presentation
	elsif ($o eq "-nobanner") {
	    $banner = 0;
	} elsif ($o eq "-banner") {
	    $banner = 1;
	}
	elsif ($o eq "-main") {
	    $do_main = 1;
	} elsif ($o eq "-nomain") {
	    $do_main = 0;
	} elsif ($o eq "-src") {
	    $show_src = 1;
	}
	elsif ($o =~ /^-stash=(.*)/) {
	    my $pkg = $1;
	    no strict 'refs';
	    if (! %{$pkg.'::'}) {
		eval "require $pkg";
	    } else {
		require Config;
		if (!$Config::Config{usedl}
		    && keys %{$pkg.'::'} == 1
		    && $pkg->can('bootstrap')) {
		    # It is something that we're staticly linked to, but hasn't
		    # yet been used.
		    eval "require $pkg";
		}
	    }
	    push @render_packs, $pkg;
	} else {
	    warn "Option $o unrecognized";
	}
    }
    return (@args);
}

sub compile {
    my (@args) = compileOpts(@_);
    return sub {
	my @newargs = compileOpts(@_); # accept new rendering options
	warn "disregarding non-options: @newargs\n" if @newargs;

	for my $objname (@args) {
	    next unless $objname; # skip null args to avoid noisy responses

	    if ($objname eq "BEGIN") {
		concise_specials("BEGIN", $order,
				 B::begin_av->isa("B::AV") ?
				 B::begin_av->ARRAY : ());
	    } elsif ($objname eq "INIT") {
		concise_specials("INIT", $order,
				 B::init_av->isa("B::AV") ?
				 B::init_av->ARRAY : ());
	    } elsif ($objname eq "CHECK") {
		concise_specials("CHECK", $order,
				 B::check_av->isa("B::AV") ?
				 B::check_av->ARRAY : ());
	    } elsif ($objname eq "UNITCHECK") {
		concise_specials("UNITCHECK", $order,
				 B::unitcheck_av->isa("B::AV") ?
				 B::unitcheck_av->ARRAY : ());
	    } elsif ($objname eq "END") {
		concise_specials("END", $order,
				 B::end_av->isa("B::AV") ?
				 B::end_av->ARRAY : ());
	    }
	    else {
		# convert function names to subrefs
		my $objref;
		if (ref $objname) {
		    print $walkHandle "B::Concise::compile($objname)\n"
			if $banner;
		    $objref = $objname;
		} else {
		    $objname = "main::" . $objname unless $objname =~ /::/;
		    print $walkHandle "$objname:\n";
		    no strict 'refs';
		    unless (exists &$objname) {
			print $walkHandle "err: unknown function ($objname)\n";
			return;
		    }
		    $objref = \&$objname;
		}
		concise_subref($order, $objref, $objname);
	    }
	}
	for my $pkg (@render_packs) {
	    no strict 'refs';
	    concise_stashref($order, \%{$pkg.'::'});
	}

	if (!@args or $do_main or @render_packs) {
	    print $walkHandle "main program:\n" if $do_main;
	    concise_main($order);
	}
	return @args;	# something
    }
}

sub compile {
    my @args = @_;
    my $order = @args ? shift(@args) : "";
    # HACK: exec must be kept for backwards compat
    $order = "-exec" if $order eq "exec";
    unshift @args, $order if $order ne "";
    B::clearsym();
    if (@args) {
      if ($order eq '-exec') {
        return sub { walkoptree_exec(main_start, "debug") }
      } else {
        return sub { walkoptree(main_root, "debug") }
      }
    } else {
      if ($order eq '-exec') {
        return sub { walkoptree_exec(main_root, "debug") }
      } else {
        return sub { walkoptree(main_root, "debug") }
      }
    }
}

1;

__END__

=head1 NAME

B::Debug - Walk Perl syntax tree, printing debug info about ops

=head1 SYNOPSIS

        perl -MO=Debug foo.pl
        perl -MO=Debug,-exec foo.pl
        perl -MO=Debug,foo::func foo.pl

=head1 DESCRIPTION

See F<ext/B/README> and the newer L<B::Concise>, L<B::Terse>.

=head1 OPTIONS

Arguments that don't start with a hyphen are taken to be the names of
subroutines to render; if no such functions are specified, the main
body of the program (outside any subroutines, and not including use'd
or require'd files) is rendered.  Passing C<BEGIN>, C<UNITCHECK>,
C<CHECK>, C<INIT>, or C<END> will cause all of the corresponding
special blocks to be printed.  Arguments must follow options.

Options affect how things are printed. They're presented
here by their visual effect, 1st being strongest.  They're grouped
according to how they interrelate; within each group the options are
mutually exclusive (unless otherwise stated).

With option C<-exec>, walks tree in execute order,
otherwise in basic order.

For backwards compatibility the option C<exec> means C<-exec>,
the sub C<exec> can be printed with C<-MO=Debug,main::exec>.

=head2 Options for Opcode Ordering

These options control the vertical flow of opcodes.

=over 4

=item B<-basic>

Print OPs in the order they appear in the OP tree (a preorder
traversal, starting at the root). This mode is the default, so the flag
is included simply for completeness.

=item B<-exec>

Print OPs in the order they would normally execute (for the majority
of constructs this is a postorder traversal of the tree, ending at the
root). In most cases the OP that usually follows a given OP will
appear directly below it; alternate paths are added afterwards.

=back

=head2 Options controlling sequence numbering

=over 4

=item B<-base>I<n>

Print OP sequence numbers in base I<n>. If I<n> is greater than 10, the
digit for 11 will be 'a', and so on. If I<n> is greater than 36, the digit
for 37 will be 'A', and so on until 62. Values greater than 62 are not
currently supported. The default is 36.

=item B<-bigendian>

Print sequence numbers with the most significant digit first. This is the
usual convention for Arabic numerals, and the default.

=item B<-littleendian>

Print seqence numbers with the least significant digit first.  This is
obviously mutually exclusive with bigendian.

=back

=head2 Other options

=over 4

=item B<-src>

With this option, the rendering of each statement (starting with the
nextstate OP) will be preceded by the 1st line of source code that
generates it.

=item B<-stash="somepackage">

With this, "somepackage" will be required, then the stash is
inspected, and each function is rendered.

=back

The following options are pairwise exclusive.

=over 4

=item B<-main>

Include the main program in the output, even if subroutines were also
specified.  This rendering is normally suppressed when a subroutine
name or reference is given.

=item B<-nomain>

This restores the default behavior after you've changed it with '-main'
(it's not normally needed).  If no subroutine name/ref is given, main is
rendered, regardless of this flag.

=back

=head1 AUTHOR

Malcolm Beattie, C<mbeattie@sable.ox.ac.uk>
Reini Urban C<rurban@cpan.org>

=head1 LICENSE

Copyright (c) 1996, 1997 Malcolm Beattie
Copyright (c) 2008, 2010 Reini Urban

	This program is free software; you can redistribute it and/or modify
	it under the terms of either:

	a) the GNU General Public License as published by the Free
	Software Foundation; either version 1, or (at your option) any
	later version, or

	b) the "Artistic License" which comes with this kit.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either
    the GNU General Public License or the Artistic License for more details.

    You should have received a copy of the Artistic License with this kit,
    in the file named "Artistic".  If not, you can get one from the Perl
    distribution. You should also have received a copy of the GNU General
    Public License, in the file named "Copying". If not, you can get one
    from the Perl distribution or else write to the Free Software Foundation,
    Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA.

=cut
