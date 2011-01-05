package C4::Reserves;

# Copyright 2000-2002 Katipo Communications
#           2006 SAN Ouest Provence
#           2007 BibLibre Paul POULAIN
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA


use strict;
# use warnings;  # FIXME: someday
use Carp;

use C4::Context;
use C4::Biblio;
use C4::Items;
use C4::Search;
use C4::Circulation;
use C4::Accounts;
use C4::Dates;
use C4::Calendar;
use C4::Stats;

# for _koha_notify_reserve
use C4::Members::Messaging;
use C4::Members qw();
use C4::Letters;
use C4::Branch qw( GetBranchDetail );
use C4::Dates qw( format_date_in_iso );
use List::MoreUtils qw( firstidx );
use Date::Calc qw(Today Add_Delta_Days);
use Time::Local;
        
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

=head1 NAME

C4::Reserves - Koha functions for dealing with reservation.

=head1 SYNOPSIS

  use C4::Reserves;

=head1 DESCRIPTION

  this modules provides somes functions to deal with reservations.
  
  Reserves are stored in reserves table.
  The following columns contains important values :
  - priority >0      : then the reserve is at 1st stage, and not yet affected to any item.
             =0      : then the reserve is being dealed
  - found : NULL       : means the patron requested the 1st available, and we haven't choosen the item
            T(ransit)  : the reserve is linked to an item but is in transit to the pickup branch
            W(aiting)  : the reserve is linked to an item, is at the pickup branch, and is waiting on the hold shelf
            F(inished) : the reserve has been completed, and is done
            R(trace)   : the reserve is set to 'trace'--which I don't know what this means yet -hQ
  - itemnumber : empty : the reserve is still unaffected to an item
                 filled: the reserve is attached to an item
  The complete workflow is :
  ==== 1st use case ====
  patron request a document, 1st available :                      P >0, F=NULL, I=NULL
  a library having it run "transfertodo", and clic on the list    
         if there is no transfer to do, the reserve waiting
         patron can pick it up                                    P =0, F=W,    I=filled 
         if there is a transfer to do, write in branchtransfer    P =0, F=T,    I=filled
           The pickup library recieve the book, it check in       P =0, F=W,    I=filled
  The patron borrow the book                                      P =0, F=F,    I=filled
  
  ==== 2nd use case ====
  patron requests a document, a given item,
    If pickup is holding branch                                   P =0, F=W,   I=filled
    If transfer needed, write in branchtransfer                   P =0, F=T,    I=filled
        The pickup library receive the book, it checks it in      P =0, F=W,    I=filled
  The patron borrow the book                                      P =0, F=F,    I=filled
  
=head1 FUNCTIONS

=over 2

=cut

BEGIN {
    # set the version for version checking
    $VERSION = 3.01;
	require Exporter;
    @ISA = qw(Exporter);
    @EXPORT = qw(
        &AddReserve
  
        &GetReservesFromItemnumber
        &GetReservesFromBiblionumber
        &GetReservesFromBorrowernumber
        &GetOldReservesFromBorrowernumber
        &ModOldReservesDisplay
        &GetReservesForBranch
        &GetReservesToBranch
        &GetReserveCount
        &GetReserveFee
        &GetReserveInfo
    
        &GetOtherReserves
        
        &ModReserveFill
        &ModReserveAffect
        &ModReserve
        &ModReserveStatus
        &ModReserveCancelAll
        &ModReserveMinusPriority
        
        &CheckReserves
        &CancelReserve
        &CancelReserves

        &SuspendReserve
        &ResumeReserve
        &GetSuspendedReservesFromBiblionumber
        &GetSuspendedReservesFromBorrowernumber
        &ResumeSuspendedReservesWithResumeDate
        
        &IsAvailableForItemLevelRequest
        
        &CanHoldMultipleItems
        &BorrowerHasReserve
    );
}

sub SaveHoldInQueue
{
   my %new = @_;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare(sprintf("
         INSERT INTO tmp_holdsqueue(%s) VALUES(%s)",
         join(',',keys %new),
         join(',',map{'?'}keys %new)
      )
   ) || die $dbh->errstr();
   $sth->execute(values %new) || die $dbh->errstr();
   return 1;
}

sub DupecheckQueue
{
   my $reservenumber = shift;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("
      SELECT 1
        FROM tmp_holdsqueue
       WHERE reservenumber = ?");
   $sth->execute($reservenumber);
   return ($sth->fetchrow_array)[0];
}

sub GetItemForBibPrefill
{
   my $res = shift;
   my $dbh = C4::Context->dbh;
   
   ## other items of the same bib are ineligible for this hold
   my $sth = $dbh->prepare("SELECT itemnumber
      FROM reserves
     WHERE biblionumber = ?
       AND priority > 0  /* is in the queue */
       AND found IS NULL /* has not been filled/waiting/in transit */
       AND reservedate <= CURRENT_DATE()
       AND reservenumber != ?") || die $dbh->errstr();
   $sth->execute($$res{biblionumber},$$res{reservenumber});
   my @items = $sth->fetchrow_array();
   
   my $sql = sprintf("
      SELECT biblio.title,
             items.itemnumber,
             items.itemcallnumber,
             items.barcode,
             items.holdingbranch
        FROM items,biblio
       WHERE items.biblionumber = ? %s
         AND items.biblionumber = biblio.biblionumber",
      @items? sprintf("AND items.itemnumber NOT IN (%s)", 
         join(',',map{'?'}@items)) : ''
   );
   $sth = $dbh->prepare($sql) || die $dbh->errstr();
   $sth->execute($$res{biblionumber},@items) || die $dbh->errstr();
   my $item = $sth->fetchrow_hashref();
   $$item{borrowercategory} = $$res{categorycode};
   return _itemfillbib($item);
}

sub GetItemForQueue
{
   my($biblionumber,$itemnumber,$borrowercategory) = @_;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("
      SELECT biblio.title,
             items.itemnumber,
             items.itemcallnumber,
             items.barcode,
             items.holdingbranch
        FROM items,biblio
       WHERE biblio.biblionumber = items.biblionumber
         AND items.biblionumber = ?
         AND items.itemnumber   = ?") || die $dbh->errstr();
   $sth->execute($biblionumber,$itemnumber) || die $dbh->errstr();
   my $item = $sth->fetchrow_hashref();
   $$item{borrowercategory} = $borrowercategory;
   return _itemfillbib($item);
}


sub _itemfillbib
{
   my $item = shift;
   my $dbh = C4::Context->dbh;
   my $sth;

   return unless IsAvailableForItemLevelRequest($$item{itemnumber});
   ## check issuing rules
   $sth = $dbh->prepare("
      SELECT biblioitems.itemtype
        FROM biblioitems,items
       WHERE items.biblionumber = biblioitems.biblionumber
         AND items.biblionumber = ?
         AND items.biblioitemnumber = biblioitems.biblioitemnumber
         AND items.itemnumber = ?");
   $sth->execute($$item{biblionumber},$$item{itemnumber});
   $$item{itemtype} = ($sth->fetchrow_array)[0];
   my $ir = C4::Circulation::GetIssuingRule(
      $$item{borrowercategory},
      $$item{itemtype},
      $$item{homebranch},
   );
   return if !$$ir{holdallowed};
   return $item;
}

# this deletes cancelled holds from the Holds Queue
sub UnorphanCancelledHolds
{
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("SELECT tmp_holdsqueue.reservenumber FROM reserves
      RIGHT JOIN tmp_holdsqueue ON reserves.reservenumber = tmp_holdsqueue.reservenumber
      WHERE reserves.reservenumber IS NULL");
   $sth->execute();
   while(my $row = $sth->fetchrow_hashref()) {
      my $sth2 = $dbh->prepare("DELETE FROM tmp_holdsqueue WHERE reservenumber = ?");
      $sth2->execute($$row{reservenumber});
   }
}

sub GetReservesForQueue
{
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("
      SELECT reserves.reservenumber,
             reserves.biblionumber,
             reserves.itemnumber,
             borrowers.surname,
             borrowers.firstname,
             borrowers.phone,
             reserves.borrowernumber,
             borrowers.cardnumber,
             borrowers.categorycode,
             reserves.reservedate,
             reserves.branchcode as pickbranch,
             reserves.reservenotes as notes
        FROM reserves,borrowers
       WHERE reserves.found IS NULL
         AND reserves.priority = 1
         AND reserves.reservedate <= CURRENT_DATE()
         AND reserves.borrowernumber = borrowers.borrowernumber
   ") || die $dbh->errstr();
   $sth->execute() || die $dbh->errstr();
   my @all = ();
   while(my $row = $sth->fetchrow_hashref()) { push @all, $row; }
   return \@all;
}

sub GetHoldsQueueItems 
{
	my ($branchlimit,$itemtypelimit) = @_;
	my $dbh = C4::Context->dbh;

   my @bind_params = ();
	my $query = q|SELECT 
         tmp_holdsqueue.*, 
         biblio.author, 
         items.ccode, 
         items.location, 
         items.enumchron, 
         items.cn_sort, 
         biblioitems.publishercode,
         biblio.copyrightdate,
         biblioitems.publicationyear,
         biblioitems.pages,
         biblioitems.size,
         biblioitems.publicationyear,
         biblioitems.isbn
   FROM tmp_holdsqueue
        JOIN biblio      USING (biblionumber)
   LEFT JOIN biblioitems USING (biblionumber)
   LEFT JOIN items       USING (  itemnumber)
   |;
    if ($branchlimit) {
	    $query .="WHERE tmp_holdsqueue.holdingbranch = ? ";
        push @bind_params, $branchlimit;
    }
    $query .= " ORDER BY ccode, location, cn_sort, author, title, pickbranch, reservedate";
	my $sth = $dbh->prepare($query);
	$sth->execute(@bind_params);
	my $items = [];
   use C4::Dates 'format_date';
    while ( my $row = $sth->fetchrow_hashref ){
		  $row->{reservedate} = format_date($row->{reservedate});
        push @$items, $row;
    }
    return $items;
}


=item AddReserve

    AddReserve($branch,$borrowernumber,$biblionumber,$constraint,$bibitems,$priority,$notes,$title,$checkitem,$found)

=cut

sub AddReserve {
    my (
        $branch,    $borrowernumber, $biblionumber,
        $constraint, $bibitems,  $priority, $resdate,  $notes,
        $title,      $checkitem, $found
    ) = @_;
    my $dbh     = C4::Context->dbh;
    my $const   = lc substr( $constraint, 0, 1 );
    $resdate = format_date_in_iso( $resdate ) if ( $resdate );
    $resdate = C4::Dates->today( 'iso' ) unless ( $resdate );
    if ( C4::Context->preference( 'AllowHoldDateInFuture' ) ) {
	# Make room in reserves for this before those of a later reserve date
	$priority = _ShiftPriorityByDateAndPriority( $biblionumber, $resdate, $priority );
    }
    my $waitingdate;

    # If the reserv had the waiting status, we had the value of the resdate
    if ( $found eq 'W' ) {
        $waitingdate = $resdate;
    }

    # updates take place here
    my $query = qq/
        INSERT INTO reserves
            (borrowernumber,biblionumber,reservedate,branchcode,constrainttype,
            priority,reservenotes,itemnumber,found,waitingdate)
        VALUES
             (?,?,?,?,?,
             ?,?,?,?,?)
    /;
    my $sth = $dbh->prepare($query);
    $sth->execute(
        $borrowernumber, $biblionumber, $resdate, $branch,
        $const,          $priority,     $notes,   $checkitem,
        $found,          $waitingdate
    );

    # Assign holds fee if applicable
    my $fee =
      GetReserveFee( $borrowernumber, $biblionumber, $constraint, $bibitems );
    if ( $fee > 0 ) {
        my $nextacctno = &getnextacctno( $borrowernumber );
        my $query      = qq/
        INSERT INTO accountlines
            (borrowernumber,accountno,date,amount,description,accounttype,amountoutstanding)
        VALUES
            (?,?,now(),?,?,'Res',?)
    /;
        my $usth = $dbh->prepare($query);
        $usth->execute( $borrowernumber, $nextacctno, $fee,
            "Reserve Charge - $title", $fee );

    }

    ($const eq "o" || $const eq "e") or return;   # FIXME: why not have a useful return value?
    $query = qq/
        INSERT INTO reserveconstraints
            (borrowernumber,biblionumber,reservedate,biblioitemnumber)
        VALUES
            (?,?,?,?)
    /;
    $sth = $dbh->prepare($query);    # keep prepare outside the loop!
    foreach (@$bibitems) {
        $sth->execute($borrowernumber, $biblionumber, $resdate, $_);
    }

    UpdateStats(
      $branch,
      my $type = 'reserve',
      my $amount,
      my $other = $biblionumber,
      my $itemnum,
      my $itemtype,
      $borrowernumber,
      my $accountno
    );

    return;     # FIXME: why not have a useful return value?
}

=item GetReservesFromBiblionumber

($count, $title_reserves) = &GetReserves($biblionumber);

This function gets the list of reservations for one C<$biblionumber>, returning a count
of the reserves and an arrayref pointing to the reserves for C<$biblionumber>.

=cut

sub GetReservesFromBiblionumber {
    my ($biblionumber) = shift or return (0, []);
    my ($all_dates) = shift;
    my ($bib_level_only) = shift;
    my $dbh   = C4::Context->dbh;

    # Find the desired items in the reserves
    my $query = "
        SELECT  reserves.reservenumber,
                reserves.branchcode,
                reserves.timestamp AS rtimestamp,
                reserves.priority,
                reserves.biblionumber,
                reserves.borrowernumber,
                reserves.reservedate,
                reserves.constrainttype,
                reserves.found,
                reserves.itemnumber,
                reserves.reservenotes,
                biblioitems.itemtype
        FROM     reserves
        LEFT JOIN biblioitems ON biblioitems.biblionumber = reserves.biblionumber
        WHERE reserves.biblionumber = ? ";
    unless ( $all_dates ) {
        $query .= "AND reservedate <= CURRENT_DATE() ";
    }
    if ( $bib_level_only ) {
        $query .= "AND reserves.itemnumber IS NULL ";
    }
    $query .= "ORDER BY reserves.priority";
    my $sth = $dbh->prepare($query);
    $sth->execute($biblionumber);
    my @results;
    my $i = 0;
    while ( my $data = $sth->fetchrow_hashref ) {
        # FIXME - What is this doing? How do constraints work?
        if ($data->{constrainttype} eq 'o') {
            $query = '
                SELECT biblioitemnumber
                FROM  reserveconstraints
                WHERE  biblionumber   = ?
                AND   borrowernumber = ?
                AND   reservedate    = ?
            ';
            my $csth = $dbh->prepare($query);
            $csth->execute($data->{biblionumber}, $data->{borrowernumber}, $data->{reservedate});
            my @bibitemno;
            while ( my $bibitemnos = $csth->fetchrow_array ) {
                push( @bibitemno, $bibitemnos );    # FIXME: inefficient: use fetchall_arrayref
            }
            my $count = scalar @bibitemno;
    
            # if we have two or more different specific itemtypes
            # reserved by same person on same day
            my $bdata;
            if ( $count > 1 ) {
                $bdata = GetBiblioItemData( $bibitemno[$i] );   # FIXME: This doesn't make sense.
                $i++; #  $i can increase each pass, but the next @bibitemno might be smaller?
            }
            else {
                # Look up the book we just found.
                $bdata = GetBiblioItemData( $bibitemno[0] );
            }
            # Add the results of this latest search to the current
            # results.
            # FIXME - An 'each' would probably be more efficient.
            foreach my $key ( keys %$bdata ) {
                $data->{$key} = $bdata->{$key};
            }
        }
        push @results, $data;
    }
    return ( $#results + 1, \@results );
}

sub GetSuspendedReservesFromBiblionumber {
    my ( $biblionumber ) = @_;
    my $dbh   = C4::Context->dbh;

    # Find the desired items in the reserves
    my $query = "SELECT *
        FROM  reserves_suspended, borrowers
        WHERE biblionumber = ?
        AND borrowers.borrowernumber = reserves_suspended.borrowernumber
        ORDER BY priority";
    my $sth = $dbh->prepare($query);
    $sth->execute($biblionumber);
    my @results;
    while ( my $data = $sth->fetchrow_hashref ) {
        push @results, $data;
    }
    return ( $#results + 1, \@results );
}

=item GetReservesFromItemnumber

 ( $reservenumber, $reservedate, $borrowernumber, $branchcode ) = GetReservesFromItemnumber($itemnumber);

   TODO :: Description here

=cut

sub GetReservesFromItemnumber {
    my ( $itemnumber, $all_dates ) = @_;
    my $dbh   = C4::Context->dbh;
    my $query = "
    SELECT reservenumber,reservedate,borrowernumber,branchcode
    FROM   reserves
    WHERE  itemnumber=?
    ";
    unless ( $all_dates ) {
	$query .= " AND reservedate <= CURRENT_DATE()";
    }
    my $sth_res = $dbh->prepare($query);
    $sth_res->execute($itemnumber);
    my ( $reservenumber, $reservedate, $borrowernumber,$branchcode ) = $sth_res->fetchrow_array;
    return ( $reservenumber, $reservedate, $borrowernumber, $branchcode );
}

=item GetReservesFromBorrowernumber

    $borrowerreserv = GetReservesFromBorrowernumber($borrowernumber,$status);
    
    TODO :: Description
    
=cut

sub GetReservesFromBorrowernumber {
    my ( $borrowernumber, $status ) = @_;
    my $dbh   = C4::Context->dbh;
    my $sth;
    if ($status) {
        $sth = $dbh->prepare("
            SELECT *
            FROM   reserves
            WHERE  borrowernumber=?
                AND found =?
            ORDER BY reservedate
        ");
        $sth->execute($borrowernumber,$status);
    } else {
        $sth = $dbh->prepare("
            SELECT *
            FROM   reserves
            WHERE  borrowernumber=?
            ORDER BY reservedate
        ");
        $sth->execute($borrowernumber);
    }
    my $data = $sth->fetchall_arrayref({});
    return @$data;
}

=item GetOldReservesFromBorrowernumber

    $borroweroldreserv = GetOldReservesFromBorrowernumber($borrowernumber,$type);

    where $type = 'cancellation|expiration|fill';

    TODO :: Description

=cut

sub GetOldReservesFromBorrowernumber {
    my ( $borrowernumber, $type) = @_;
    my $dbh   = C4::Context->dbh;
    my $sth;
    if ($type eq 'expiration') {
        $sth = $dbh->prepare("
            SELECT *
            FROM   old_reserves
            WHERE  borrowernumber=?
                AND expirationdate IS NOT NULL
            ORDER BY expirationdate DESC
        ");
        $sth->execute($borrowernumber);
    } elsif ($type eq 'cancellation') {
        $sth = $dbh->prepare("
            SELECT *
            FROM   old_reserves
            WHERE  borrowernumber=?
                AND cancellationdate IS NOT NULL
            ORDER BY cancellationdate DESC
        ");
        $sth->execute($borrowernumber);
    } else {
        $sth = $dbh->prepare("
            SELECT *
            FROM   old_reserves
            WHERE  borrowernumber=?
                AND priority = 'F'
            ORDER BY timestamp DESC
        ");
        $sth->execute($borrowernumber);
    }
    my $data = $sth->fetchall_arrayref({});
    return @$data;
}

=item ModOldReservesDisplay

  ModOldReservesDisplay($reservenumber);

=cut

sub ModOldReservesDisplay {
    my ($reservenumber) = @_;
    my $dbh = C4::Context->dbh;
    my $sth;
    $sth = $dbh->prepare("
        UPDATE old_reserves
        SET displayexpired = 0
        WHERE reservenumber = ?
    ");
    $sth->execute($reservenumber);
    return();
}

=item GetReservesByBorrowernumberAndItemtype

    $borrowerreserv = GetReservesByBorrowernumberAndItemtypeOf($borrowernumber, $biblionumber);
    
    TODO :: Descritpion
    
=cut

sub GetReservesByBorrowernumberAndItemtypeOf {
    my ( $borrowernumber, $biblionumber ) = @_;
    my $dbh   = C4::Context->dbh;
    my $sth;

    $sth = $dbh->prepare("SELECT itemtype FROM biblioitems WHERE biblionumber = ?");
    $sth->execute( $biblionumber );
    my $res = $sth->fetchrow_hashref();
    my $itemtype = $res->{'itemtype'};

    $sth = $dbh->prepare("
            SELECT *
            FROM   reserves, biblioitems
            WHERE  borrowernumber=?
            AND reserves.biblionumber = biblioitems.biblionumber
            AND biblioitems.itemtype = ?
            ORDER BY reservedate
    ");
    $sth->execute($borrowernumber,$itemtype);
    my $data = $sth->fetchall_arrayref({});
    return @$data;
}

#-------------------------------------------------------------------------------------
sub BorrowerHasReserve {
    my ( $borrowernumber, $biblionumber, $itemnumber ) = @_;
    my $dbh   = C4::Context->dbh;
    my $sth;
    
    if ( $biblionumber ) {
      $sth = $dbh->prepare("
            SELECT COUNT(*) AS hasReserve
            FROM   reserves
            WHERE  borrowernumber = ?
            AND    biblionumber = ?
            ORDER BY reservedate
        ");
      $sth->execute( $borrowernumber, $biblionumber );
    } elsif ( $itemnumber ) {
      $sth = $dbh->prepare("
            SELECT COUNT(*) AS hasReserve
            FROM   reserves
            WHERE  borrowernumber = ?
            AND    itemnumber = ?
            ORDER BY reservedate
        ");
      $sth->execute( $borrowernumber, $itemnumber );
    } else {
      return -1;
    }

    my $data = $sth->fetchrow_hashref();
    return $data->{'hasReserve'};
}

=item GetReservesFromBorrowernumber

    $suspended_reserves = GetSuspendedReservesFromBorrowernumber($borrowernumber);
    
=cut

sub GetSuspendedReservesFromBorrowernumber {
    my ( $borrowernumber ) = @_;
    my $dbh   = C4::Context->dbh;
    my $sth;
    $sth = $dbh->prepare("
        SELECT *
        FROM   reserves_suspended
        WHERE  borrowernumber=?
        ORDER BY reservedate
    ");
    $sth->execute($borrowernumber);
    my $data = $sth->fetchall_arrayref({});
    return @$data;
}

=item GetReserveCount

$number = &GetReserveCount($borrowernumber [, $today [, $shelf_holds_only]  ]);

this function returns the number of reservation for a borrower given on input arg.

If optional $today is true, will return only holds placed today.

If option $shelf_holds_only is true, will only return the count of holds placed on items not checked out.
=cut

sub GetReserveCount {
    my ($borrowernumber, $today, $shelf_holds_only ) = @_;

    my $dbh = C4::Context->dbh;

    my $query = "SELECT COUNT(*) AS counter FROM reserves WHERE borrowernumber = ?";
    
    if ( $today ) {
      $query .= ' AND DATE( reserves.timestamp ) = DATE( NOW() )';
    }

    if ( $shelf_holds_only ) {
    warn "GetReserveCount: Shelf Holds Only";
      $query = "
        SELECT COUNT( DISTINCT ( items.biblionumber ) ) AS counter
        FROM items
        LEFT JOIN issues ON issues.itemnumber = items.itemnumber
        LEFT JOIN reserves ON reserves.biblionumber = items.biblionumber
        WHERE issues.timestamp IS NULL
        AND reserves.biblionumber IS NOT NULL
        AND reserves.borrowernumber = ?
        AND DATE( reserves.timestamp ) = DATE( NOW( ) )
      ";
    }

    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    my $row = $sth->fetchrow_hashref;

    my $res_count = $row->{counter};
    return $res_count;
}

=item GetOtherReserves

($messages,$nextreservinfo)=$GetOtherReserves(itemnumber);

Check queued list of this document and check if this document must be  transfered

=cut

sub GetOtherReserves {
    my ($itemnumber) = @_;
    my $messages;
    my $nextreservinfo;
    my ( $restype, $checkreserves, $count ) = CheckReserves($itemnumber);
    if ($checkreserves) {
        my $iteminfo = GetItem($itemnumber);
        if ( $iteminfo->{'holdingbranch'} ne $checkreserves->{'branchcode'} ) {
            $messages->{'transfert'} = $checkreserves->{'branchcode'};
            #minus priorities of others reservs
            ModReserveMinusPriority(
                $itemnumber,
                $checkreserves->{'borrowernumber'},
                $iteminfo->{'biblionumber'},
                $checkreserves->{'reservenumber'}
            );

            #launch the subroutine dotransfer
            C4::Items::ModItemTransfer(
                $itemnumber,
                $iteminfo->{'holdingbranch'},
                $checkreserves->{'branchcode'},
              ),
              ;
        }

     #step 2b : case of a reservation on the same branch, set the waiting status
        else {
            $messages->{'waiting'} = 1;
            ModReserveMinusPriority(
                $itemnumber,
                $checkreserves->{'borrowernumber'},
                $iteminfo->{'biblionumber'},
                $checkreserves->{'reservenumber'}                
            );
            ModReserveStatus($itemnumber,'W',$checkreserves->{'reservenumber'});
        }

        $nextreservinfo = $checkreserves->{'borrowernumber'};
    }

    return ( $messages, $nextreservinfo );
}

=item GetReserveFee

$fee = GetReserveFee($borrowernumber,$biblionumber,$constraint,$biblionumber);

Calculate the fee for a reserve

=cut

sub GetReserveFee {
    my ($borrowernumber, $biblionumber, $constraint, $bibitems ) = @_;

    #check for issues;
    my $dbh   = C4::Context->dbh;
    my $const = lc substr( $constraint, 0, 1 );
    my $query = qq/
      SELECT * FROM borrowers
    LEFT JOIN categories ON borrowers.categorycode = categories.categorycode
    WHERE borrowernumber = ?
    /;
    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    my $data = $sth->fetchrow_hashref;
    $sth->finish();
    my $fee      = $data->{'reservefee'};
    $query = qq/
      SELECT * FROM items
    LEFT JOIN itemtypes ON items.itype = itemtypes.itemtype
    WHERE biblionumber = ?
    /;
    my $isth = $dbh->prepare($query);
    $isth->execute($biblionumber);
    my $idata = $isth->fetchrow_hashref;
    $fee += $idata->{'reservefee'};

    my $cntitems = @- > $bibitems;

    if ( $fee > 0 ) {

        # check for items on issue
        # first find biblioitem records
        my @biblioitems;
        my $sth1 = $dbh->prepare(
            "SELECT * FROM biblio LEFT JOIN biblioitems on biblio.biblionumber = biblioitems.biblionumber
                   WHERE (biblio.biblionumber = ?)"
        );
        $sth1->execute($biblionumber);
        while ( my $data1 = $sth1->fetchrow_hashref ) {
            if ( $const eq "a" ) {
                push @biblioitems, $data1;
            }
            else {
                my $found = 0;
                my $x     = 0;
                while ( $x < $cntitems ) {
                    if ( @$bibitems->{'biblioitemnumber'} ==
                        $data->{'biblioitemnumber'} )
                    {
                        $found = 1;
                    }
                    $x++;
                }
                if ( $const eq 'o' ) {
                    if ( $found == 1 ) {
                        push @biblioitems, $data1;
                    }
                }
                else {
                    if ( $found == 0 ) {
                        push @biblioitems, $data1;
                    }
                }
            }
        }
        $sth1->finish;
        my $cntitemsfound = @biblioitems;
        my $issues        = 0;
        my $x             = 0;
        my $allissued     = 1;
        while ( $x < $cntitemsfound ) {
            my $bitdata = $biblioitems[$x];
            my $sth2    = $dbh->prepare(
                "SELECT * FROM items
                     WHERE biblioitemnumber = ?"
            );
            $sth2->execute( $bitdata->{'biblioitemnumber'} );
            while ( my $itdata = $sth2->fetchrow_hashref ) {
                my $sth3 = $dbh->prepare(
                    "SELECT * FROM issues
                       WHERE itemnumber = ?"
                );
                $sth3->execute( $itdata->{'itemnumber'} );
                if ( my $isdata = $sth3->fetchrow_hashref ) {
                }
                else {
                    $allissued = 0;
                }
            }
            $x++;
        }
        if ( $allissued == 0 ) {
            my $rsth =
              $dbh->prepare("SELECT * FROM reserves WHERE biblionumber = ?");
            $rsth->execute($biblionumber);
            if ( my $rdata = $rsth->fetchrow_hashref ) {
            }
            else {
                $fee = 0;
            }
        }
    }
    return $fee;
}

=item GetReservesToBranch

@transreserv = GetReservesToBranch( $frombranch );

Get reserve list for a given branch

=cut

sub GetReservesToBranch {
    my ( $frombranch ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare(
        "SELECT borrowernumber,reservedate,itemnumber,timestamp
         FROM reserves 
         WHERE priority='0' 
           AND branchcode=?"
    );
    $sth->execute( $frombranch );
    my @transreserv;
    my $i = 0;
    while ( my $data = $sth->fetchrow_hashref ) {
        $transreserv[$i] = $data;
        $i++;
    }
    return (@transreserv);
}

=item GetReservesForBranch

@transreserv = GetReservesForBranch($frombranch);

=cut

sub GetReservesForBranch {
    my ($frombranch) = @_;
    my $dbh          = C4::Context->dbh;
	my $query        = "SELECT borrowernumber,reservedate,itemnumber,waitingdate,reservenumber
        FROM   reserves 
        WHERE   priority='0'
            AND found='W' ";
    if ($frombranch){
        $query .= " AND branchcode=? ";
	}
    $query .= "ORDER BY waitingdate" ;
    my $sth = $dbh->prepare($query);
    if ($frombranch){
		$sth->execute($frombranch);
	}
    else {
		$sth->execute();
	}
    my @transreserv;
    my $i = 0;
    while ( my $data = $sth->fetchrow_hashref ) {
        $transreserv[$i] = $data;
        $i++;
    }
    return (@transreserv);
}

=item CheckReserves

  ($status, $reserve, $count) = &CheckReserves($itemnumber);

Find a book in the reserves.

C<$itemnumber> is the book's item number.

As I understand it, C<&CheckReserves> looks for the given item in the
reserves. If it is found, that's a match, and C<$status> is set to
C<Waiting>.

Otherwise, it finds the most important item in the reserves with the
same biblio number as this book (I'm not clear on this) and returns it
with C<$status> set to C<Reserved>.

C<&CheckReserves> returns a three-element list:

C<$status> is either C<Waiting>, C<Reserved> (see above), or 0.

C<$reserve> is the reserve item that matched. It is a
reference-to-hash whose keys are mostly the fields of the reserves
table in the Koha database.

C<$count> is the number of reserves for this item.

=cut

sub CheckReserves {
    my ( $item, $barcode ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth;
    my $select = "
    SELECT items.biblionumber,
           items.biblioitemnumber,
           itemtypes.notforloan,
           items.notforloan AS itemnotforloan,
           items.itemnumber,
           items.itype,
           items.homebranch
    FROM   items
    LEFT JOIN biblioitems ON items.biblioitemnumber = biblioitems.biblioitemnumber
    LEFT JOIN itemtypes   ON biblioitems.itemtype   = itemtypes.itemtype
    ";

    if ($item) {
        $sth = $dbh->prepare("$select WHERE itemnumber = ?");
        $sth->execute($item);
    }
    else {
        $sth = $dbh->prepare("$select WHERE barcode = ?");
        $sth->execute($barcode);
    }
    # note: we get the itemnumber because we might have started w/ just the barcode.  Now we know for sure we have it.
    my ( $biblio, $bibitem, $notforloan_per_itemtype, $notforloan_per_item, $itemnumber, $itemtype, $itembranch ) = $sth->fetchrow_array;

    return ( 0, 0, 0 ) unless $itemnumber; # bail if we got nothing.

    # if item is not for loan it cannot be reserved either.....
    #    execption to notforloan is where items.notforloan < 0 :  This indicates the item is holdable. 
    return ( 0, 0, 0 ) if  ( $notforloan_per_item > 0 ) or $notforloan_per_itemtype;

    # Find this item in the reserves
    my @reserves = _Findgroupreserve( $bibitem, $biblio, $itemnumber );

    # $priority and $highest are used to find the most important item
    # in the list returned by &_Findgroupreserve. (The lower $priority,
    # the more important the item.)
    # $highest is the most important item we've seen so far.
    my $highest;
    my $exact;
    my $local;
    my $oldest;

    my $count = @reserves;
    my $nohold = 0;
    if (@reserves) {
        my $priority = 10000000;
        foreach my $res (@reserves) {
            my $issuingrule = C4::Circulation::GetIssuingRule ($$res{borrowercategory},$itemtype,$itembranch);
            unless ($issuingrule) {
               next;
            }
            if (!$issuingrule->{'holdallowed'}) {
              $nohold++;
              next;
            }
            # FIXME - $item might be undefined or empty: the caller
            # might be searching by barcode.
            if ( $res->{'itemnumber'} == $item && $res->{'priority'} == 0) {
                # Found it
                $exact = $res;
                last;
            }
            else {
                # See if this item is more important than what we've got
                # so far.
                $res->{'nullitem'} = 1 if (!defined($res->{'itemnumber'}));
                if ( $res->{'priority'} != 0 && $res->{'priority'} < $priority )
                {
                    $priority = $res->{'priority'};
                    $highest  = $res;
                }
            }
        }
    }

    if ( 
      ( $count > C4::Context->preference('HoldsTransportationReductionThreshold') )
      || 
      ( C4::Context->preference('HoldsTransportationReductionThreshold') eq '0' ) 
    ) {
      $local = GetReserve_NextLocalReserve( $item, $barcode );
      $oldest = GetReserve_OldestReserve( $item, $barcode );
      
      undef $oldest unless ( 
        not defined $oldest ||
            ($oldest->{'age_in_days'} > C4::Context->preference('FillRequestsAtPickupLibraryAge') &&
             $oldest->{'priority'} < $local->{'priority'}
            )
      );
    }

    if ($nohold==$count) { return (0,0,0) }
    if ( $oldest ) {
      return( 'Reserved', $oldest, $count );
    } elsif ( $local ) {
      return( 'Reserved', $local, $count );
    } elsif ( $exact ) {
        # Found an exact match, return it
        return ( "Waiting", $exact, $count );
    } elsif ($highest) {
        # If we get this far, then no exact match was found.
        # We return the most important (i.e. next) reservation.
        $highest->{'itemnumber'} = $item;
        return ( "Reserved", $highest, $count );
    }
    else {
        return ( 0, 0, 0 );
    }
}

=item GetReserve_NextLocalReserve

  my $reserve = GetReserve_NextLocalReserve( $itemnumber[, $barcode ] );
  
  Returns the highest priority reserve for the given itemnumber/barcode
  whose pickup location is the logged in branch, if any.  
=cut

sub GetReserve_NextLocalReserve {
  my ( $itemnumber, $barcode ) = @_;

  my $branchcode = C4::Context->userenv->{"branch"};
  
  my $dbh = C4::Context->dbh;
  my $sth;
  
  my $item = GetItem( $itemnumber, $barcode );
  $itemnumber = $item->{'itemnumber'};
  my $biblionumber = $item->{'biblionumber'};
  my $biblioitemnumber = $item->{'biblioitemnumber'};

  my $reserve;
  $reserve->{'priority'} = 10000000;

  my @reserves = _Findgroupreserve( $biblioitemnumber, $biblionumber, $itemnumber );

  foreach my $r (@reserves) {
      $reserve = $r if ( $r->{'branchcode'} eq $branchcode && $r->{'priority'} < $reserve->{'priority'} );
  }

  # Itemnumber was never getting set
  $reserve->{'itemnumber'} = $itemnumber;
  return $reserve if ( defined $reserve->{'branchcode'} );
}

=item GetReserve_OldestReserve

  my $reserve = GetReserve_OldestReserve( $itemnumber[, $barcode ] );
  
  Returns the oldest reserve for the given itemnumber/barcode, if any.
  
=cut

sub GetReserve_OldestReserve {
  my ( $itemnumber, $barcode ) = @_;
  my $branchcode = C4::Context->userenv->{"branch"};
  
  my $item = GetItem( $itemnumber, $barcode );
  $itemnumber = $item->{'itemnumber'};
  my $biblionumber = $item->{'biblionumber'};
  my $biblioitemnumber = $item->{'biblioitemnumber'};

  my $reserve;

  my @reserves = _Findgroupreserve( $biblioitemnumber, $biblionumber, $itemnumber );
  foreach my $r (@reserves) {
      $reserve = $r if ( $r->{'timestamp'} > $reserve->{'timestamp'} ); # Isn't $reserve->{'timestamp'} undefined?
  }
  
  # Itemnumber was never getting set
  $reserve->{'itemnumber'} = $itemnumber;
  return $reserve if ( defined $reserve->{'branchcode'} );
}

=item CancelReserves
  &CancelReserves({
    [ biblionumber => $biblionumber, ]
    [ itemnumber => $itemnumber, ]
  });
  
  Cancels all the reserves for the given itemnumber
  or biblionumber. If both are supllied, all the reserves
  for the given biblio are deleted, as the reserves for
  the given itemnumber would be included.
  
=cut

sub CancelReserves {
    my ( $params ) = @_;
    my $biblionumber = $params->{'biblionumber'};
    my $itemnumber   = $params->{'itemnumber'};
    
    my $dbh = C4::Context->dbh;
    
    return unless $biblionumber || $itemnumber;

    my @sql_params;

    my $sql = "SELECT reservenumber, biblionumber FROM reserves WHERE ";
    if ( $itemnumber ) {
      $sql .= " itemnumber = ? ";
      push( @sql_params, $itemnumber );
    } else {
      $sql .= " biblionumber = ?";
      push( @sql_params, $biblionumber );
    }
    
    my $sth = $dbh->prepare( $sql );
    $sth->execute( @sql_params );
    
    while ( my $reserve = $sth->fetchrow_hashref() ) {
      CancelReserve( $reserve->{'reservenumber'}, $reserve->{'biblionumber'} );
    }
}

sub _moveToOldReserves {
    my $reservenumber = shift;
    my $dbh = C4::Context->dbh;
    my $sth;
    my $query;

    $query = "INSERT INTO old_reserves SELECT * FROM reserves WHERE reservenumber = ?";
    $sth = $dbh->prepare($query);
    $sth->execute($reservenumber) or
        croak sprintf "Cannot transfer reserve '%d': %s\n", $reservenumber//-1, $dbh->errstr;

    $query = "DELETE FROM reserves WHERE reservenumber = ?";
    $sth = $dbh->prepare($query);
    $sth->execute($reservenumber) or
        croak sprintf "Cannot delete reserve '%d': %s\n", $reservenumber//-1, $dbh->errstr;
}

=item CancelReserve

  &CancelReserve( $reservenumber );

Cancels a reserve.

C<$reservenumber> is the unique key for the reserve to be canceled.

C<&CancelReserve> also adjusts the priorities of the other people
who are waiting on the book.

=cut

sub CancelReserve {
    my ( $reservenumber ) = @_;
    my $dbh = C4::Context->dbh;

    my $branchcode = C4::Context->userenv->{'branch'};
 
    # Pull borrowernumber of the user performing the action for logging
    my $moduser = C4::Context->userenv->{'number'};
    
    my $sth = $dbh->prepare('SELECT * FROM reserves WHERE reservenumber = ?');
    $sth->execute( $reservenumber );
    my $reserve = $sth->fetchrow_hashref();

    my $borrowernumber = $reserve->{'borrowernumber'};
    my $biblionumber = $reserve->{'biblionumber'};
    if ( $reserve->{'found'} eq 'W' ) {
        # removing a waiting reserve record....
        # update the database...
        my $query = "
            UPDATE reserves
            SET    cancellationdate = now(),
                   found            = Null,
                   priority         = 0,
                   expirationdate   = NULL
            WHERE  reservenumber    = ?
        ";
        my $sth = $dbh->prepare($query);
        $sth->execute( $reservenumber );
    }
    else {
        # removing a reserve record....
        # get the priority on this record....
        my $priority;
        my $query = qq/
            SELECT priority FROM reserves
            WHERE reservenumber = ?
              AND cancellationdate IS NULL
              AND itemnumber IS NULL
        /;
        my $sth = $dbh->prepare($query);
        $sth->execute( $reservenumber );
        ($priority) = $sth->fetchrow_array;
        $query = qq/
            UPDATE reserves
            SET    cancellationdate = now(),
                   found            = Null,
                   priority         = 0,
                   expirationdate   = NULL
            WHERE  reservenumber   = ?
        /;
        $sth = $dbh->prepare($query);
        $sth->execute( $reservenumber );

        _FixPriority( '', '', $priority, $reservenumber );
    }

    _moveToOldReserves($reservenumber);
    UpdateReserveCancelledStats(
      $branchcode,'reserve_canceled',undef,$biblionumber,
      $reserve->{'itemnumber'},undef,$reserve->{'borrowernumber'},
      undef,$moduser
    );
    
    # Send cancellation notice, if desired
    my $mprefs = C4::Members::Messaging::GetMessagingPreferences( { 
      borrowernumber => $borrowernumber,
      message_name   => 'Hold Cancelled'
    } );
    if ( $mprefs->{'transports'} ) {
      my $borrower = C4::Members::GetMember( $borrowernumber, 'borrowernumber');
      my $biblio = GetBiblioData($biblionumber) or die sprintf "BIBLIONUMBER: %d\n", $biblionumber;
      my $letter = C4::Letters::getletter( 'reserves', 'HOLD_CANCELLED');
      my $admin_email_address = C4::Context->preference('KohaAdminEmailAddress');                

      my %keys = (%$borrower, %$biblio);
      $keys{'branchname'} = C4::Branch::GetBranchName( $branchcode );
      my $replacefield;
      foreach my $key (keys %keys) {
        foreach my $table qw(biblio borrowers branches items reserves) {
          $replacefield = "<<$table.$key>>";
          $letter->{content} =~ s/$replacefield/$keys{$key}/g;
        }
      }
        
      C4::Letters::EnqueueLetter(
        { letter                 => $letter,
          borrowernumber         => $borrower->{'borrowernumber'},
          message_transport_type => $mprefs->{'transports'}->[0],
          from_address           => $admin_email_address,
          to_address             => $borrower->{'email'},
        }
      );
    }
}

=item ModReserve

=over 4

ModReserve($rank, $biblio, $borrower, $branch[, $itemnumber])

=back

Change a hold request's priority or cancel it.

C<$rank> specifies the effect of the change.  If C<$rank>
is 'W' or 'n', nothing happens.  This corresponds to leaving a
request alone when changing its priority in the holds queue
for a bib.

If C<$rank> is 'del', the hold request is cancelled.

If C<$rank> is an integer greater than zero, the priority of
the request is set to that value.  Since priority != 0 means
that the item is not waiting on the hold shelf, setting the 
priority to a non-zero value also sets the request's found
status and waiting date to NULL. 

The optional C<$itemnumber> parameter is used only when
C<$rank> is a non-zero integer; if supplied, the itemnumber 
of the hold request is set accordingly; if omitted, the itemnumber
is cleared.

FIXME: Note that the forgoing can have the effect of causing
item-level hold requests to turn into title-level requests.  This
will be fixed once reserves has separate columns for requested
itemnumber and supplying itemnumber.

=cut

sub ModReserve {
    #subroutine to update a reserve
    my ( $rank, $biblio, $borrower, $branch , $itemnumber, $reservenumber ) = @_;
    # Pull borrowernumber of the user performing the action for logging
    my $moduser = C4::Context->userenv->{'number'};
     return if $rank eq "W";
     return if $rank eq "n";
    my $dbh = C4::Context->dbh;
    if ( $rank eq "del" ) {
        my $query = qq/
            UPDATE reserves
            SET    cancellationdate=now(),
                   expirationdate = NULL
            WHERE  reservenumber   = ?
        /;
        my $sth = $dbh->prepare($query);
        $sth->execute( $reservenumber );
        $sth->finish;

        _moveToOldReserves($reservenumber);
        
        UpdateReserveCancelledStats(
          $branch,'reserve_canceled',undef,$biblio,
          $itemnumber,undef,$borrower,undef,$moduser
        );

        # Send expiration notice, if desired
        my $borrowernumber = $borrower;
        my $biblionumber = $biblio;
        my $branchcode = $branch;
        my $mprefs = C4::Members::Messaging::GetMessagingPreferences( {
          borrowernumber => $borrowernumber,
          message_name   => 'Hold Cancelled'
        } );
        if ( $mprefs->{'transports'} ) {
          my $borrower = C4::Members::GetMember( $borrowernumber, 'borrowernumber');
          my $biblio = GetBiblioData($biblionumber) or die sprintf "BIBLIONUMBER: %d\n", $biblionumber;
          my $letter = C4::Letters::getletter( 'reserves', 'HOLD_CANCELLED');
          my $admin_email_address = C4::Context->preference('KohaAdminEmailAddress');

          my %keys = (%$borrower, %$biblio);
          $keys{'branchname'} = C4::Branch::GetBranchName( $branchcode );
          my $replacefield;
          foreach my $key (keys %keys) {
            foreach my $table qw(biblio borrowers branches items reserves) {
              $replacefield = "<<$table.$key>>";
              $letter->{content} =~ s/$replacefield/$keys{$key}/g;
            }
          }

          C4::Letters::EnqueueLetter(
            { letter                 => $letter,
              borrowernumber         => $borrower->{'borrowernumber'},
              message_transport_type => $mprefs->{'transports'}->[0],
              from_address           => $admin_email_address,
              to_address             => $borrower->{'email'},
            }
          );
        }

    }
    elsif ($rank =~ /^\d+/ and $rank > 0) {
        my $query = qq/
        UPDATE reserves SET priority = ? ,branchcode = ?, itemnumber = ?, found = NULL, waitingdate = NULL, expirationdate = NULL
            WHERE reservenumber = ?
        /;
        my $sth = $dbh->prepare($query);
        $sth->execute( $rank, $branch, $itemnumber, $reservenumber );
        $sth->finish;
        _FixPriority( $biblio, $borrower, $rank, $reservenumber );
    }
}


sub _getNextBranchInQueue
{
   my($currLib,$queue_sofar) = @_;
   my $nextLib  = '';
   my @branches;
   my $nextpref = C4::Context->preference('NextLibraryHoldsQueueWeight');
   my $staypref = C4::Context->preference('StaticHoldsQueueWeight');
   my $dorand   = C4::Context->preference('RandomizeHoldsQueueWeight');
   if ($nextpref) {
      @branches = split(/\,\s*/,$nextpref);
   }
   elsif ($staypref) {
      @branches = split(/\,\s*/, $staypref);
   }
   else {
      @branches = keys %{C4::Branch::GetBranches()};
   }

   if (@branches && !$dorand) {
      BRANCH:
      for my $i(0..$#branches) {
         if ($branches[$i] eq $currLib) {
            if ($i+1 >scalar@branches) {
               $nextLib = $branches[0];
            }
            else {
               $nextLib = $branches[$i+1];
            }
            last BRANCH;
         }
      }
      $nextLib ||= $branches[0];
   }
   elsif ($dorand) {
      use List::Util qw(shuffle);
      @branches = shuffle @branches; 
      my @q = split(/\,/, $queue_sofar);
      if (scalar @q >= scalar @branches) {
         @q = splice(@q,-1*(@q%@branches));         
      }
      my %seen = ();
      foreach(@q) { $seen{$_}++ }
      foreach(@branches) {
         next if $seen{$_};
         $nextLib = $_;
         last;
      }
      $nextLib ||= $branches[0];
      $nextLib = $branches[-1] if $nextLib eq $currLib;
      $nextLib = $branches[-2] if $nextLib eq $currLib;
   }
   return $nextLib;
}

sub ModReservePass
{
   my $res = shift;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("
      SELECT queue_sofar
        FROM tmp_holdsqueue
       WHERE reservenumber = ?");
   $sth->execute($$res{reservenumber});

   ## figure out the next library to pass to
   my $q = ($sth->fetchrow_array)[0];
   my($currLib) = $q =~/\,?(\w+)$/;
   $q  .= ',' . _getNextBranchInQueue($currLib,$q);
   $sth = $dbh->prepare("UPDATE tmp_holdsqueue
      SET queue_sofar    = ?
    WHERE reservenumber  = ?");
   $sth->execute($q,$$res{reservenumber});
   return $q;
}

=item ModReserveFill

  &ModReserveFill($reserve);

Fill a reserve. If I understand this correctly, this means that the
reserved book has been found and given to the patron who reserved it.

C<$reserve> specifies the reserve to fill. It is a reference-to-hash
whose keys are fields from the reserves table in the Koha database.

=cut

sub ModReserveFill {
    my $res = shift; # the reserves hash should be complete
    my $dbh = C4::Context->dbh;
    # fill in a reserve record....
    my $biblionumber = $res->{'biblionumber'};
    my $borrowernumber = $res->{'borrowernumber'};
    my $reservenumber = $res->{'reservenumber'};
    my $resdate = $res->{'reservedate'};

    # get the priority on this record....
    my $priority = $$res{priority};
    
    # update the database...F=filled
    my $query = "UPDATE reserves
                  SET    found            = 'F',
                         priority         = 0,
                         expirationdate   = NULL
                 WHERE  biblionumber     = ?
                    AND reservedate      = ?
                    AND borrowernumber   = ?
                ";
    my $sth = $dbh->prepare($query);
    $sth->execute( $biblionumber, $resdate, $borrowernumber );
    $sth->finish;

    _moveToOldReserves($reservenumber);
    
    # now fix the priority on the others (if the priority wasn't
    # already sorted!)....
    unless ( $priority == 0 ) {
        _FixPriority( $biblionumber, $borrowernumber, $priority, $reservenumber );
    }

    # delete from holds queue
    foreach my $table(qw(tmp_holdsqueue)) {
       $sth = $dbh->prepare("DELETE FROM $table
          WHERE reservenumber = ?");
       $sth->execute($$res{reservenumber});
    }
    return 1; # return true on success
}

sub ModReserveTrace
{
   my $res = shift;
   my $dbh = C4::Context->dbh;
   my $sth;
   
   # update item's status
   $sth = $dbh->prepare("
      UPDATE items
         SET otherstatus = 'trace'
       WHERE itemnumber = ?");
   $sth->execute($$res{itemnumber});

   # update the database
   my $sql = "UPDATE reserves
              SET    found            = 'R',
                     priority         = 0,
                     expirationdate   = NULL
              WHERE  reservenumber    = ?";
   $sth = $dbh->prepare($sql) || die $dbh->errstr();
   $sth->execute($$res{reservenumber});

   # remove from queue
   foreach(qw(tmp_holdsqueue)) {
       $sth = $dbh->prepare("DELETE FROM $_
       WHERE reservenumber = ?");
       $sth->execute($$res{reseservenumber});
    }
     

    $sth->finish;
    return 1;
}

=item ModReserveStatus

&ModReserveStatus($itemnumber, $newstatus, $reservenumber);

Update the reserve status for the active (priority=0) reserve.

$itemnumber is the itemnumber the reserve is on

$newstatus is the new status.

$reservenumber is the reserves.reservenumber

=cut

sub ModReserveStatus {
    #first : check if we have a reservation for this item .
    my ($itemnumber, $newstatus, $reservenumber) = @_;
    my $dbh          = C4::Context->dbh;
    my ($query,$sth,$sth_set);

# Need to account for hold expiration date, since it hasn't been calculated
# at this point.
    my $holdperiod = C4::Context->preference('ReservesMaxPickUpDelay');
    if (defined($holdperiod) && ($holdperiod > 0)) {
      my ($holdexpyear,$holdexpmonth,$holdexpday) = Today();
      my $holdstartdate = C4::Dates->new(sprintf "%02d/%02d/%04d",$holdexpmonth,$holdexpday,$holdexpyear, 'us');

      # Grab branch for calendar purposes
      $sth = $dbh->prepare("SELECT branchcode FROM reserves WHERE reservenumber=?");
      $sth->execute($reservenumber);
      my ($branch) = $sth->fetchrow;

      # Check to see if hold expiration date falls on a closed library day.
      # Note the useDaysMode syspref will need to be set to Calendar for
      # the code to advance to the next non-closed day.
      my $calendar = C4::Calendar->new( branchcode => $branch);
      my $holdexpdate  = $calendar->addDate($holdstartdate, $holdperiod);
      my $sqlexpdate = $holdexpdate->output('iso');
      $query = "
          UPDATE reserves
          SET    found = ?,
                 waitingdate = now(),
                 expirationdate = '$sqlexpdate'
          WHERE itemnumber = ?
            AND found IS NULL
            AND priority = 0
      ";
      $sth_set = $dbh->prepare($query);
      $sth_set->execute( $newstatus, $itemnumber );
    }
    else {
      $query = "
          UPDATE reserves
          SET    found=?,
                 waitingdate = now()
          WHERE itemnumber=?
             AND found IS NULL
             AND priority = 0
      ";
      $sth_set = $dbh->prepare($query);
      $sth_set->execute( $newstatus, $itemnumber );
    }

    if ( C4::Context->preference("ReturnToShelvingCart") && $newstatus ) {
      CartToShelf( $itemnumber );
    }
}

=item ModReserveAffect

&ModReserveAffect($itemnumber,$borrowernumber,$diffBranchSend);

This function affect an item and a status for a given reserve
The itemnumber parameter is used to find the biblionumber.
with the biblionumber & the borrowernumber, we can affect the itemnumber
to the correct reserve.

if $transferToDo is not set, then the status is set to "Waiting" as well.
otherwise, a transfer is on the way, and the end of the transfer will 
take care of the waiting status
=cut

sub ModReserveAffect {
    my ( $itemnumber, $borrowernumber,$transferToDo, $reservenumber ) = @_;
    my $dbh = C4::Context->dbh;
    # we want to attach $itemnumber to $borrowernumber, find the biblionumber
    # attached to $itemnumber
    my $sth = $dbh->prepare("SELECT biblionumber FROM items WHERE itemnumber=?");
    $sth->execute($itemnumber);
    my ($biblionumber) = $sth->fetchrow;

    # get request - need to find out if item is already
    # waiting in order to not send duplicate hold filled notifications
    my $request = GetReserveInfo($borrowernumber, $biblionumber);
    my $already_on_shelf = ($request && $request->{found} eq 'W') ? 1 : 0;

    # If we affect a reserve that has to be transfered, don't set to Waiting
    my $query;
    if ($transferToDo) {
    $query = "
        UPDATE reserves
        SET    priority = 0,
               itemnumber = ?,
               found = 'T'
        WHERE reservenumber = ?
    ";
    }
    else {
    # affect the reserve to Waiting as well.
      my $holdperiod = C4::Context->preference('ReservesMaxPickUpDelay');
      if ((!defined($holdperiod)) || ($holdperiod eq '') || ($holdperiod == 0)) {
        $query = "
            UPDATE reserves
            SET     priority = 0,
                    found = 'W',
                    waitingdate=now(),
                    itemnumber = ?
            WHERE reservenumber = ?
        ";
      }
      else {
        my ($holdexpyear,$holdexpmonth,$holdexpday) = Today();
        my $holdstartdate = C4::Dates->new(sprintf "%02d/%02d/%04d",$holdexpmonth,$holdexpday,$holdexpyear, 'us');

        # Grab branch for calendar purposes
        $sth = $dbh->prepare("SELECT branchcode FROM reserves WHERE reservenumber=?");
        $sth->execute($reservenumber);
        my ($branch) = $sth->fetchrow;

        # Check to see if hold expiration date falls on a closed library day.
        # Note the useDaysMode syspref will need to be set to Calendar for
        # the code to advance to the next non-closed day.
        my $calendar = C4::Calendar->new( branchcode => $branch);
        my $holdexpdate  = $calendar->addDate($holdstartdate, $holdperiod);
        my $sqlexpdate = $holdexpdate->output('iso');
        $query = "
            UPDATE reserves
            SET     priority = 0,
                    found = 'W',
                    waitingdate=now(),
                    itemnumber = ?,
                    expirationdate='$sqlexpdate'
        WHERE reservenumber = ?
        ";
      }
    }
    $sth = $dbh->prepare($query);
    $sth->execute( $itemnumber, $reservenumber );
    _koha_notify_reserve( $itemnumber, $borrowernumber, $biblionumber, $reservenumber ) if ( !$transferToDo && !$already_on_shelf );

    if ( C4::Context->preference("ReturnToShelvingCart") ) {
      CartToShelf( $itemnumber );
    }

    return;
}

=item ModReserveCancelAll

($messages,$nextreservinfo) = &ModReserveCancelAll($reservenumber,$itemnumber);

    function to cancel reserv,check other reserves, and transfer document if it's necessary

=cut

sub ModReserveCancelAll {
    my ( $reservenumber, $itemnumber ) = @_;
    my $messages;
    my $nextreservinfo;

    #step 1 : cancel the reservation
    my $CancelReserve = CancelReserve( $reservenumber );

    #step 2 launch the subroutine of the others reserves
    ( $messages, $nextreservinfo ) = GetOtherReserves($itemnumber);

    return ( $messages, $nextreservinfo );
}

=item ModReserveMinusPriority

&ModReserveMinusPriority($itemnumber,$borrowernumber,$biblionumber,$reservenumber)

Reduce the values of queuded list     

=cut

sub ModReserveMinusPriority {
    my ( $itemnumber, $borrowernumber, $biblionumber, $reservenumber ) = @_;
    #first step update the value of the first person on reserv
    my $dbh   = C4::Context->dbh;
    my $query = "
        UPDATE reserves
        SET    priority = 0 , itemnumber = ? 
        WHERE  reservenumber=?
    ";
    my $sth_upd = $dbh->prepare($query);
    $sth_upd->execute( $itemnumber, $reservenumber );
    # second step update all others reservs
    _FixPriority($biblionumber, $borrowernumber, '0', $reservenumber );
}

sub GetReserve
{
   my $reservenumber = shift;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare('SELECT * FROM reserves WHERE reservenumber = ?');
   $sth->execute($reservenumber);
   return $sth->fetchrow_hashref();
}

=item GetReserveInfo

&GetReserveInfo($borrowernumber,$biblionumber);

 Get item and borrower details for a current hold.
 Current implementation this query should have a single result.
=cut

sub GetReserveInfo {
	my ( $borrowernumber, $biblionumber ) = @_;
    my $dbh = C4::Context->dbh;
	my $strsth="SELECT reservedate, reservenotes, reserves.borrowernumber,
				reserves.biblionumber, reserves.branchcode,
				notificationdate, reminderdate, priority, found,
				firstname, surname, phone, 
				email, address, address2,
				cardnumber, city, zipcode,
				biblio.title, biblio.author,
				items.holdingbranch, items.itemcallnumber, items.itemnumber, 
				homebranch, barcode, notes
			FROM reserves left join items 
				ON items.itemnumber=reserves.itemnumber , 
				borrowers, biblio 
			WHERE 
				reserves.borrowernumber=?  &&
				reserves.biblionumber=? && 
				reserves.borrowernumber=borrowers.borrowernumber && 
				reserves.biblionumber=biblio.biblionumber ";
	my $sth = $dbh->prepare($strsth); 
	$sth->execute($borrowernumber,$biblionumber);

	my $data = $sth->fetchrow_hashref;
	return $data;

}

=item IsAvailableForItemLevelRequest

=over 4

my $is_available = IsAvailableForItemLevelRequest($itemnumber);

=back

Checks whether a given item record is available for an
item-level hold request.  An item is available if

* it is not lost
* it is not damaged (if syspref AllowHoldsOnDamagedItems=Off)
* it is not withdrawn
* it is not suppressed
* it is not marked notforloan (is false)
* it is not currently in transit
* it is not set to trace or other blocking status
* it is not on loan (see below)
* itemstatus
      holdsallowed = 1
      holdsfilled  = 1
Does not check
* issuing rule blocks
* is sitting on the hold shelf (reserves.found = 'W'aiting)

Whether or not the item is currently on loan is 
also checked - if the AllowOnShelfHolds system preference
is ON, an item can be requested even if it is currently
on loan to somebody else.  If the system preference
is OFF, an item that is currently checked out cannot
be the target of an item-level hold request.

Note that IsAvailableForItemLevelRequest() does not
check if the staff operator is authorized to place
a request on the item - in particular,
this routine does not check IndependantBranches
and canreservefromotherbranches.

=cut

sub IsAvailableForItemLevelRequest {
    my $itemnumber = shift;
    my $item = GetItem($itemnumber);
    my $dbh = C4::Context->dbh;
    my $sth;

    return 0 if $$item{itemlost};
    return 0 if $$item{wthdrawn};
    return 0 if $$item{suppress};
    if ($$item{otherstatus}) {
       $sth = $dbh->prepare('SELECT holdsallowed,holdsfilled
          FROM itemstatus
         WHERE statuscode = ?');
       $sth->execute($$item{otherstatus});
       my($holdsallowed,$holdsfilled) = $sth->fetchrow_array();
       return 0 unless ($holdsallowed && $holdsfilled);
    }

    ## check in transit
    $sth = $dbh->prepare('SELECT 1 FROM branchtransfers
       WHERE itemnumber = ?');
    $sth->execute($itemnumber);
    return 0 if ($sth->fetchrow_array)[0];

    # must check the notforloan setting of the itemtype
    # FIXME - a lot of places in the code do this
    #         or something similar - need to be
    #         consolidated
    my $notforloan_query;
    if (C4::Context->preference('item-level_itypes')) {
        $notforloan_query = "SELECT itemtypes.notforloan
                             FROM items
                             JOIN itemtypes ON (itemtypes.itemtype = items.itype)
                             WHERE itemnumber = ?";
    } else {
        $notforloan_query = "SELECT itemtypes.notforloan
                             FROM items
                             JOIN biblioitems USING (biblioitemnumber)
                             JOIN itemtypes ON ( itemtypes.itemtype = biblioitems.itemtype )
                             WHERE itemnumber = ?";
    }
    $sth = $dbh->prepare($notforloan_query);
    $sth->execute($itemnumber);
    my $notforloan_per_itemtype = 0;
    if (my ($notforloan) = $sth->fetchrow_array) {
        $notforloan_per_itemtype = 1 if $notforloan;
    }

    my $available_per_item = 1;
    $available_per_item = 0 if $item->{itemlost} or
                               ( $item->{notforloan} > 0 ) or
                               ($item->{damaged} and not C4::Context->preference('AllowHoldsOnDamagedItems')) or
                               $item->{wthdrawn} or
                               $notforloan_per_itemtype;

    if (C4::Context->preference('AllowOnShelfHolds')) {
      return $available_per_item;
    } else {
      return ($available_per_item and $item->{onloan});
    }
}

sub CanHoldMultipleItems {
  my ( $itemtype ) = @_;
  
  my @multi_itemtypes = split( / /, C4::Context->preference('AllowMultipleHoldsPerBib') );
  for my $mtype ( @multi_itemtypes ) {
    if ( $itemtype eq $mtype ) {
      return 1;
    }
  }
  
  return 0;
}

=item _FixPriority

&_FixPriority($biblio,$borrowernumber,$rank,$reservenumber);

 Only used internally (so don't export it)
 Changed how this functions works #
 Now just gets an array of reserves in the rank order and updates them with
 the array index (+1 as array starts from 0)
 and if $rank is supplied will splice item from the array and splice it back in again
 in new priority rank

=cut 

sub _FixPriority {
    my ( $biblio, $borrowernumber, $rank, $reservenumber ) = @_;
    my $dbh = C4::Context->dbh;
     if ( $rank eq "del" ) {
         CancelReserve( $reservenumber );
     }
    if ( $rank eq "W" || $rank eq "0" ) {

        # make sure priority for waiting or in-transit items is 0
        my $query = qq/
            UPDATE reserves
            SET    priority = 0
            WHERE reservenumber = ?
              AND found IN ('W', 'T')
        /;
        my $sth = $dbh->prepare($query);
        $sth->execute( $reservenumber );
    }
    my @priority;
    my @reservedates;

    # get whats left
# FIXME adding a new security in returned elements for changing priority,
# now, we don't care anymore any reservations with itemnumber linked (suppose a waiting reserve)
	# This is wrong a waiting reserve has W set
	# The assumption that having an itemnumber set means waiting is wrong and should be corrected any place it occurs
    my $query = qq/
        SELECT borrowernumber, reservedate, constrainttype, reservenumber
        FROM   reserves
        WHERE  biblionumber   = ?
          AND  ((found <> 'W' AND found <> 'T') or found is NULL)
        ORDER BY priority ASC
    /;
    my $sth = $dbh->prepare($query);
    $sth->execute($biblio);
    while ( my $line = $sth->fetchrow_hashref ) {
        push( @reservedates, $line );
        push( @priority,     $line );
    }

    # To find the matching index
    my $i;
    my $key = -1;    # to allow for 0 to be a valid result
    for ( $i = 0 ; $i < @priority ; $i++ ) {
        if ( $borrowernumber == $priority[$i]->{'borrowernumber'} ) {
            $key = $i;    # save the index
            last;
        }
    }

    # if index exists in array then move it to new position
    if ( $key > -1 && $rank ne 'del' && $rank > 0 ) {
        my $new_rank = $rank -
          1;    # $new_rank is what you want the new index to be in the array
        my $moving_item = splice( @priority, $key, 1 );
        splice( @priority, $new_rank, 0, $moving_item );
    }

    # now fix the priority on those that are left....
    $query = "
            UPDATE reserves
            SET    priority = ?
                WHERE  reservenumber = ?
                 AND reservedate = ?
         AND found IS NULL
    ";
    $sth = $dbh->prepare($query);
    for ( my $j = 0 ; $j < @priority ; $j++ ) {
        $sth->execute(
            $j + 1, 
            $priority[$j]->{'reservenumber'},
            $priority[$j]->{'reservedate'}
        );
        $sth->finish;
    }
}

=item _Findgroupreserve

  @results = &_Findgroupreserve($biblioitemnumber, $biblionumber, $itemnumber);

Looks for an item-specific match first, then for a title-level match, returning the
first match found.  If neither, then we look for a 3rd kind of match based on
reserve constraints.

TODO: add more explanation about reserve constraints

C<&_Findgroupreserve> returns :
C<@results> is an array of references-to-hash whose keys are mostly
fields from the reserves table of the Koha database, plus
C<biblioitemnumber>.

=cut

sub _Findgroupreserve {
    my ( $bibitem, $biblio, $itemnumber ) = @_;
    my $dbh   = C4::Context->dbh;

    # TODO: consolidate at least the SELECT portion of the first 2 queries to a common $select var.
    # check for exact targetted match
    my $item_level_target_query = qq/
        SELECT reserves.reservenumber AS reservenumber,
               reserves.biblionumber AS biblionumber,
               reserves.borrowernumber AS borrowernumber,
               reserves.reservedate AS reservedate,
               reserves.branchcode AS branchcode,
               reserves.cancellationdate AS cancellationdate,
               reserves.found AS found,
               reserves.reservenotes AS reservenotes,
               reserves.waitingdate AS waitingdate,
               reserves.priority AS priority,
               reserves.timestamp AS timestamp,
               biblioitems.biblioitemnumber AS biblioitemnumber,
               reserves.itemnumber          AS itemnumber,
               borrowers.categorycode       AS borrowercategory,
               borrowers.branchcode         AS borrowerbranch,
               DATEDIFF(NOW(),reserves.timestamp) AS age_in_days
        FROM reserves
        JOIN biblioitems USING (biblionumber)
        JOIN borrowers ON (reserves.borrowernumber=borrowers.borrowernumber)
        JOIN tmp_holdsqueue ON 
             (reserves.biblionumber=tmp_holdsqueue.biblionumber AND
              reserves.borrowernumber=tmp_holdsqueue.borrowernumber AND
              reserves.itemnumber=tmp_holdsqueue.itemnumber)
        WHERE found IS NULL
        AND priority > 0
        AND item_level_request = 1
        AND reserves.itemnumber = ?
        AND reserves.reservedate <= CURRENT_DATE()
    /;
    my $sth = $dbh->prepare($item_level_target_query);
    $sth->execute($itemnumber);
    my @results;
    if ( my $data = $sth->fetchrow_hashref ) {
        push( @results, $data );
    }
    return @results if @results;
    
    # check for title-level targetted match
    my $title_level_target_query = qq/
        SELECT reserves.reservenumber AS reservenumber,
               reserves.biblionumber AS biblionumber,
               reserves.borrowernumber AS borrowernumber,
               reserves.reservedate AS reservedate,
               reserves.branchcode AS branchcode,
               reserves.cancellationdate AS cancellationdate,
               reserves.found AS found,
               reserves.reservenotes AS reservenotes,
               reserves.waitingdate AS waitingdate,
               reserves.priority AS priority,
               reserves.timestamp AS timestamp,
               biblioitems.biblioitemnumber AS biblioitemnumber,
               reserves.itemnumber          AS itemnumber,
               borrowers.categorycode       AS borrowercategory,
               borrowers.branchcode         AS borrowerbranch,
               DATEDIFF(NOW(),reserves.timestamp) AS age_in_days
        FROM reserves
        JOIN biblioitems USING (biblionumber)
        JOIN borrowers ON (reserves.borrowernumber=borrowers.borrowernumber)
        JOIN tmp_holdsqueue ON 
             (reserves.biblionumber=tmp_holdsqueue.biblionumber AND
              reserves.borrowernumber=tmp_holdsqueue.borrowernumber AND
              reserves.itemnumber=tmp_holdsqueue.itemnumber)
        WHERE found IS NULL
        AND priority > 0
        AND item_level_request = 0
        AND tmp_holdsqueue.itemnumber = ?
        AND reserves.reservedate <= CURRENT_DATE()
    /;
    $sth = $dbh->prepare($title_level_target_query);
    $sth->execute($itemnumber);
    @results = ();
    if ( my $data = $sth->fetchrow_hashref ) {
        push( @results, $data );
    }
    return @results if @results;

    my $query = qq/
        SELECT reserves.reservenumber AS reservenumber,
               reserves.biblionumber AS biblionumber,
               reserves.borrowernumber AS borrowernumber,
               reserves.reservedate AS reservedate,
               reserves.branchcode AS branchcode,
               reserves.cancellationdate AS cancellationdate,
               reserves.found AS found,
               reserves.reservenotes AS reservenotes,
               reserves.waitingdate AS waitingdate,
               reserves.priority AS priority,
               reserves.timestamp AS timestamp,
               reserveconstraints.biblioitemnumber AS biblioitemnumber,
               reserves.itemnumber                 AS itemnumber,
               borrowers.categorycode       AS borrowercategory,
               borrowers.branchcode         AS borrowerbranch,
               DATEDIFF(NOW(),reserves.timestamp) AS age_in_days
        FROM reserves
          LEFT JOIN reserveconstraints ON reserves.biblionumber = reserveconstraints.biblionumber
        JOIN borrowers ON (reserves.borrowernumber=borrowers.borrowernumber)
        WHERE reserves.biblionumber = ?
          AND ( ( reserveconstraints.biblioitemnumber = ?
          AND reserves.borrowernumber = reserveconstraints.borrowernumber
          AND reserves.reservedate    = reserveconstraints.reservedate )
          OR  reserves.constrainttype='a' )
          AND (reserves.itemnumber IS NULL OR reserves.itemnumber = ?)
          AND reserves.reservedate <= CURRENT_DATE()
    /;
    $sth = $dbh->prepare($query);
    $sth->execute( $biblio, $bibitem, $itemnumber );
    @results = ();
    while ( my $data = $sth->fetchrow_hashref ) {
        push( @results, $data );
    }
    return @results;
}

=item _koha_notify_reserve

=over 4

_koha_notify_reserve( $itemnumber, $borrowernumber, $biblionumber );

=back

Sends a notification to the patron that their hold has been filled (through
ModReserveAffect, _not_ ModReserveFill)

=cut

sub _koha_notify_reserve {
    my ($itemnumber, $borrowernumber, $biblionumber, $reservenumber) = @_;

    my $dbh = C4::Context->dbh;
    my $borrower = C4::Members::GetMember( $borrowernumber );
    my $letter_code;
    my $print_mode = 0;
    my $messagingprefs;
    if ( $borrower->{'email'} || $borrower->{'smsalertnumber'} ) {
        $messagingprefs = C4::Members::Messaging::GetMessagingPreferences( { borrowernumber => $borrowernumber, message_name => 'Hold Filled' } );

        return if ( !defined( $messagingprefs->{'letter_code'} ) );
        $letter_code = $messagingprefs->{'letter_code'};
    } else {
        $letter_code = 'HOLD_PRINT';
        $print_mode = 1;
    }

    my $sth = $dbh->prepare("
        SELECT *
        FROM   reserves
        WHERE  reservenumber = ?
    ");
    $sth->execute( $reservenumber );
    my $reserve = $sth->fetchrow_hashref;
    if (C4::Context->preference('TalkingTechEnabled')) {
      my $biblio = &GetBiblioData($biblionumber);
      my $item = &GetItem($itemnumber);
      my @items;
      $item->{'title'} = $biblio->{'title'};
      $item->{'date_due'} = $reserve->{'expirationdate'};
      push @items,$item;
      C4::Letters::CreateTALKINGtechMESSAGE($borrowernumber,\@items,'RESERVE','0');
    }

    my $branch_details = GetBranchDetail( $reserve->{'branchcode'} );

    my $admin_email_address = $branch_details->{'branchemail'} || C4::Context->preference('KohaAdminEmailAddress');

    my $letter = getletter( 'reserves', $letter_code );
    die "Could not find a letter called '$letter_code' in the 'reserves' module" unless( $letter );

    C4::Letters::parseletter( $letter, 'branches', $reserve->{'branchcode'} );
    C4::Letters::parseletter( $letter, 'borrowers', $borrowernumber );
    C4::Letters::parseletter( $letter, 'biblio', $biblionumber );
    C4::Letters::parseletter( $letter, 'reserves', $borrowernumber, $biblionumber );

    if ( $reserve->{'itemnumber'} ) {
        C4::Letters::parseletter( $letter, 'items', $reserve->{'itemnumber'} );
    }
    my $today = C4::Dates->new()->output();
    $letter->{'title'} =~ s/<<today>>/$today/g;
    $letter->{'content'} =~ s/<<today>>/$today/g;
    $letter->{'content'} =~ s/<<[a-z0-9_]+\.[a-z0-9]+>>//g; #remove any stragglers

    if ( $print_mode ) {
        C4::Letters::EnqueueLetter( {
            letter => $letter,
            borrowernumber => $borrowernumber,
            message_transport_type => 'print',
        } );
        
        return;
    }

    if ( grep { $_ eq 'email' } @{$messagingprefs->{transports}} ) {
        # aka, 'email' in ->{'transports'}
        C4::Letters::EnqueueLetter(
            {   letter                 => $letter,
                borrowernumber         => $borrowernumber,
                message_transport_type => 'email',
                from_address           => $admin_email_address,
            }
        );
    }

    if ( grep { $_ eq 'sms' } @{$messagingprefs->{transports}} ) {
        C4::Letters::EnqueueLetter(
            {   letter                 => $letter,
                borrowernumber         => $borrowernumber,
                message_transport_type => 'sms',
            }
        );
    }
}

=item _ShiftPriorityByDateAndPriority

=over 4

$new_priority = _ShiftPriorityByDateAndPriority( $biblionumber, $reservedate, $priority );

=back

This increments the priority of all reserves after the one
 with either the lowest date after C<$reservedate>
 or the lowest priority after C<$priority>.

It effectively makes room for a new reserve to be inserted with a certain
 priority, which is returned.

This is most useful when the reservedate can be set by the user.  It allows
 the new reserve to be placed before other reserves that have a later
 reservedate.  Since priority also is set by the form in reserves/request.pl
 the sub accounts for that too.

=cut

sub _ShiftPriorityByDateAndPriority {
    my ( $biblio, $resdate, $new_priority ) = @_;

    my $dbh = C4::Context->dbh;
    my $query = "SELECT priority FROM reserves WHERE biblionumber = ? AND ( reservedate > ? OR priority > ? ) ORDER BY priority ASC LIMIT 1";
    my $sth = $dbh->prepare( $query );
    $sth->execute( $biblio, $resdate, $new_priority );
    my $min_priority = $sth->fetchrow;
    # if no such matches are found, $new_priority remains as original value
    $new_priority = $min_priority if ( $min_priority );

    # Shift the priority up by one; works in conjunction with the next SQL statement
    $query = "UPDATE reserves
              SET priority = priority+1
              WHERE biblionumber = ?
              AND borrowernumber = ?
              AND reservedate = ?
              AND found IS NULL";
    my $sth_update = $dbh->prepare( $query );

    # Select all reserves for the biblio with priority greater than $new_priority, and order greatest to least
    $query = "SELECT borrowernumber, reservedate FROM reserves WHERE priority >= ? AND biblionumber = ? ORDER BY priority DESC";
    $sth = $dbh->prepare( $query );
    $sth->execute( $new_priority, $biblio );
    while ( my $row = $sth->fetchrow_hashref ) {
	$sth_update->execute( $biblio, $row->{borrowernumber}, $row->{reservedate} );
    }

    return $new_priority;  # so the caller knows what priority they wind up receiving
}

sub SuspendReserve {
    my ( $reservenumber, $resumedate ) = @_;

    my $dbh = C4::Context->dbh;
    my $sth;
    my $query;

    $query = "SELECT * FROM reserves WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    my $data = $sth->execute( $reservenumber );
    my $reserve = $sth->fetchrow_hashref();
    $sth->finish();
    
    $query = "INSERT INTO reserves_suspended SELECT * FROM reserves WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    $sth->execute( $reservenumber );
    $sth->finish();
    
    $query = "DELETE FROM reserves WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    $sth->execute( $reservenumber );
    $sth->finish();

    ## Reuse waitingdate form resumedate, suspended reserves cannot be waiting.
    if ( $resumedate ) {
      $query = "UPDATE reserves_suspended SET waitingdate = ? WHERE reservenumber = ?";
      $sth = $dbh->prepare( $query );
      $sth->execute( $resumedate, $reservenumber );
      $sth->finish();
    }
    
    _FixPriority( $reserve->{'biblionumber'}, $reserve->{'borrowernumber'}, $reserve->{'priority'}, $reservenumber );
}

sub ResumeReserve {
    my ( $reservenumber ) = @_;

    my $dbh = C4::Context->dbh;
    my $sth;
    my $query;

    $query = "SELECT * FROM reserves_suspended WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    my $data = $sth->execute( $reservenumber );
    my $suspended_reserve = $sth->fetchrow_hashref();
    $sth->finish();

    $query = "SELECT priority FROM reserves WHERE reservedate > ? AND biblionumber = ? ORDER BY reservedate ASC";
    $sth = $dbh->prepare( $query );
    $data = $sth->execute( $suspended_reserve->{'reservedate'}, $suspended_reserve->{'biblionumber'} );
    my $next_reserve = $sth->fetchrow_hashref();
    $sth->finish();
    my $new_priority = $next_reserve->{'priority'};

    $query = "INSERT INTO reserves SELECT * FROM reserves_suspended WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    $sth->execute( $reservenumber );
    $sth->finish();
    
    $query = "DELETE FROM reserves_suspended WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    $sth->execute( $reservenumber );
    $sth->finish();

    $query = "UPDATE reserves SET waitingdate = NULL WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    $data = $sth->execute( $reservenumber );
    $sth->finish();

    $query = "SELECT * FROM reserves WHERE reservenumber = ?";
    $sth = $dbh->prepare( $query );
    $data = $sth->execute( $reservenumber );
    my $reserve = $sth->fetchrow_hashref();
    $sth->finish();

    _FixPriority( $reserve->{'biblionumber'}, $reserve->{'borrowernumber'}, $new_priority, $reservenumber );
}

sub ResumeSuspendedReservesWithResumeDate {
    my $dbh = C4::Context->dbh;
    my $sth;
    my $query;

    $query = "SELECT reservenumber FROM reserves_suspended WHERE DATE(waitingdate) <= DATE( NOW() )";
    $sth = $dbh->prepare( $query );
    my $data = $sth->execute();
    my $res = $sth->fetchall_arrayref();
    $sth->finish();

    foreach my $r ( @{$res} ) {
      ResumeReserve( @$r );
    }
}

=back

=head1 AUTHOR

Koha Developement team <info@koha.org>

=cut

1;
__END__

