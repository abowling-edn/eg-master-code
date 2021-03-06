#!/usr/bin/perl

use strict;
use warnings;
use DBI;
use Getopt::Long;
use MARC::Record;
use MARC::File::XML (BinaryEncoding => 'UTF-8');
use MARC::Charset;
use OpenSRF::System;
use OpenILS::Utils::Fieldmapper;
use OpenSRF::Utils::SettingsClient;
use OpenSRF::EX qw/:try/;
use Encode;
use Unicode::Normalize;
use OpenILS::Application::AppUtils;
use Data::Dumper;
use Pod::Usage qw/ pod2usage /;

MARC::Charset->assume_unicode(1);

my $acsaf_cache = {};

sub get_acsaf {
    my ($e, $id) = @_;

    $acsaf_cache->{$id} ||=
        $e->retrieve_authority_control_set_authority_field([
            $id,
            {flesh => 1, flesh_fields => {acsaf => ["main_entry"]}}
        ]);
    return $acsaf_cache->{$id};
}

# Grab DB information from local settings. Return connected db handle (or die)
sub connect_to_db {
    my $sc = OpenSRF::Utils::SettingsClient->new;
    my $db_driver = $sc->config_value( reporter => setup => database => 'driver' );
    my $db_host = $sc->config_value( reporter => setup => database => 'host' );
    my $db_port = $sc->config_value( reporter => setup => database => 'port' );
    my $db_name = $sc->config_value( reporter => setup => database => 'db' );
    if (!$db_name) {
        $db_name = $sc->config_value( reporter => setup => database => 'name' );
        print STDERR "WARN: <database><name> is a deprecated setting for database name. For future compatibility, you should use <database><db> instead." if $db_name;
    }
    my $db_user = $sc->config_value( reporter => setup => database => 'user' );
    my $db_pw = $sc->config_value( reporter => setup => database => 'pw' );

    die "Unable to retrieve database connection information from the settings server" unless ($db_driver && $db_host && $db_port && $db_name && $db_user);

    my $dsn = "dbi:" . $db_driver . ":dbname=" . $db_name .';host=' . $db_host . ';port=' . $db_port;

    return DBI->connect(
        $dsn,$db_user,$db_pw, {
            AutoCommit => 1, pg_enable_utf8 => 1, RaiseError => 1
        }
    ); # shouldn't need 'or die...' with RaiseError=>1
}

# I can't believe this isn't already in a sub somewhere?  We seem to repeat
# these steps all over the place, which is very much "bad code smell."
sub marcxml_eg {
    my ($xml) = @_; # a string, not an object, to be clear

    $xml =~ s/\n//sgo;
    $xml =~ s/^<\?xml.+\?\s*>//go;
    $xml =~ s/>\s+</></go;
    $xml =~ s/\p{Cc}//go;

    return OpenILS::Application::AppUtils->entityize($xml);
}

sub matchable_string {
    my ($field, $sf_list, $joiner) = @_;
    $joiner ||= ' ';

    return join($joiner, map { $field->subfield($_) } split "", $sf_list);
}

# ########### main
my ($start_id, $end_id);
my $bootstrap = '/openils/conf/opensrf_core.xml';
my @records;

my %options;
my $result = GetOptions(
    \%options,
    'configuration=s' => \$bootstrap,
    'record=i' => \@records,
    'all', 'help', 'debug',
    'start_id=i' => \$start_id,
    'end_id=i' => \$end_id
);

pod2usage(0) if not $result or $options{help};

print "OpenSRF bootstrap and fieldmapper import...\n" if $options{debug};
OpenSRF::System->bootstrap_client(config_file => $bootstrap);
Fieldmapper->import(IDL => OpenSRF::Utils::SettingsClient->new->config_value("IDL"));

# must be loaded and initialized after the IDL is parsed

print "Loading CStoreEditor ...\n" if $options{debug};

use OpenILS::Utils::CStoreEditor;
OpenILS::Utils::CStoreEditor::init();

my $e = OpenILS::Utils::CStoreEditor->new;

my $query = q{
    SELECT
        source,
        ARRAY_TO_STRING(ARRAY_AGG(target || ',' || field), ';') AS links
        FROM (
            SELECT  sh1.record AS target,
                sh2.record AS source,
                sh2.atag AS field
            FROM  authority.simple_heading sh1
                JOIN authority.simple_heading sh2 USING (sort_value)
                JOIN authority.control_set_authority_field af1 ON (sh1.atag = af1.id AND af1.main_entry IS NULL)
                JOIN authority.control_set_authority_field af2 ON (sh2.atag = af2.id AND af2.main_entry IS NOT NULL AND af2.linking_subfield IS NOT NULL)
                %s -- where clause here
            EXCEPT SELECT target, source, field FROM authority.authority_linking
    ) x GROUP BY 1
};

my @bind_params;
if (@records) {
    $query = sprintf($query, "WHERE sh2.record = ?");
    @bind_params = @records;    # should be just one scalar in this array.
} elsif ($options{all}) {
    $query = sprintf($query, ""); # no where clause
} elsif ($start_id and $end_id) {
    $query = sprintf($query, "WHERE sh2.record BETWEEN ? AND ?");
    @bind_params = ($start_id, $end_id);
} else {
    pod2usage(0);
}

print "SQL, params: ", Dumper($query, \@bind_params), "\n" if $options{debug};
my $dbh = connect_to_db; # dies if any problem
my $sth = $dbh->prepare($query);

print "Executing query ...\n" if $options{debug};
$sth->execute(@bind_params);

my $problems = 0;

while (my ($src, $links) = $sth->fetchrow_array) {
    print "src: $src\n" if $options{debug};

    try {
        my $src_rec = $e->retrieve_authority_record_entry($src) or
            die $e->die_event;
        my $src_marc = MARC::Record->new_from_xml($src_rec->marc);

        for my $link (split ';', $links) {
            my ($target, $field_id) = split ',', $link;

            print "target: $target, field_id: $field_id\n" if $options{debug};

            my $target_rec = $e->retrieve_authority_record_entry($target) or
                    die $e->die_event;
            my $target_marc = MARC::Record->new_from_xml($target_rec->marc);
            my $cni = $target_marc->field('003')->data;

            my $acsaf = get_acsaf($e, $field_id) or die $e->die_event;

            for my $field ($src_marc->field($acsaf->tag)) {
                my $src_string = matchable_string(
                    $field, $acsaf->main_entry->display_sf_list, $acsaf->main_entry->joiner
                );

                print("at field ", $acsaf->id, " (", $acsaf->tag,
                    "), trying to match '$src_string'...\n") if $options{debug};

                my ($tfield) = $target_marc->field($acsaf->main_entry->tag);
                my $target_string = matchable_string(
                    $tfield, $acsaf->main_entry->display_sf_list, $acsaf->main_entry->joiner
                );

                if ($target_string eq $src_string) {
                    print "got a match ...\n" if $options{debug};
                    $field->update('0' => "($cni)$target");
                }
            }
        }

        $src_rec->marc(marcxml_eg($src_marc->as_xml_record));

        $e->xact_begin;
        $e->update_authority_record_entry($src_rec) or
            die $e->die_event;
        $e->xact_commit;

    } otherwise {
        my $err = shift;
        print STDERR "\nRecord # $src : ",
            (ref $err eq "HASH" ? Dumper($err) : $err), "\n";

        # Reset SAX parser so that one bad record doesn't
        # kill the entire process.

        import MARC::File::XML;
        $problems++;
    }
}

exit ($problems > 0);

__END__

=head1 NAME

authority_authority_linker.pl - Link reference headings in authority records to main entry headings in other authority records

=head1 SYNOPSIS

authority_authority_linker.pl [B<--configuration>=I<opensrf_core.conf>]
[[B<--record>=I<record>[ B<--record>=I<record>]]] | [B<--all>] | [B<--start_id>=I<start-ID> B<--end_id>=I<end-ID>]

=head1 DESCRIPTION

For a given set of records, find authority reference headings that also
appear as main entry headings in any other authority record. In the
specific MARC field of the authority record (source) containing the reference
heading with such a match in another authority record (target), add a subfield
0 (zero) referring to the target record by ID.

=head1 OPTIONS

=over

=item * B<-c> I<config-file>, B<--configuration>=I<config-file>

Specifies the OpenSRF configuration file used to connect to the OpenSRF router.
Defaults to F</openils/conf/opensrf_core.xml>

=item * B<-r> I<record-ID>, B<--record>=I<record-ID>

Specifies the authority record ID (found in the C<authority.record_entry.id>
column) of the B<source> record to process. This option may be specified more
than once to process multiple records in a single run.

=item * B<-a>, B<--all>

Specifies that all authority records should be processed. For large
databases, this may take an extraordinarily long amount of time.

=item * B<-s> I<start-ID>, B<--start_id>=I<start-ID>

Specifies the starting ID of the range of authority records to process.
This option is ignored unless it is accompanied by the B<-e> or B<--end_id>
option.

=item * B<-e> I<end-ID>, B<--end_id>=I<end-ID>

Specifies the ending ID of the range of authority records to process.
This option is ignored unless it is accompanied by the B<-s> or B<--start>
option.

=back

=head1 EXAMPLES

    authority_authority_linker.pl --start_id 1 --end_id 50000

Processes the authority records with IDs between 1 and 50,000 using the
default OpenSRF configuration file for connection information.

=head1 AUTHOR

Lebbeous Fogle-Weekley <lebbeous@esilibrary.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 Equinox Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

=cut
