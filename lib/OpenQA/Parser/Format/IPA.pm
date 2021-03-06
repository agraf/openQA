# Copyright (C) 2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Parser::Format::IPA;

# Translates to JSON IPA format -> OpenQA internal representation
# The parser results will be a collection of OpenQA::Parser::Result::IPA::Test
use Mojo::Base 'OpenQA::Parser::Format::Base';
use Carp qw(croak confess);
use Cpanel::JSON::XS ();
use OpenQA::Parser::Result::Test;

sub _add_single_result { shift->results->add(OpenQA::Parser::Result::OpenQA->new(@_)) }

# Parser
sub parse {
    my ($self, $json) = @_;
    confess "No JSON given/loaded" unless $json;
    my $decoded_json = Cpanel::JSON::XS->new->utf8(0)->decode($json);

    # may be optional since format result_array:v2
    $self->generated_tests_extra->add(OpenQA::Parser::Result::IPA::Info->new($decoded_json->{info}))
      if $decoded_json->{info};

    foreach my $res (@{$decoded_json->{tests}}) {
        my $result = {};
        my $t_name = $res->{name};
        $t_name =~ s/\[\w+:\/\/(\d+\.){3}\d+//;
        $t_name =~ s/\]$//;

        $result->{result} = 'fail';
        $result->{result} = 'ok' if $res->{outcome} =~ /passed/i;
        $result->{result} = 'skip' if $res->{outcome} =~ /skipped/i;

        $t_name =~ s/[:\/\[\]\.]/_/g;    # dots in the filename confuse the web api routes
        $result->{name} = $t_name;

        my $details = {result => $result->{result}};
        my $text_fn = "IPA-$t_name.txt";
        my $content = join("\n", $res->{name}, $result->{result});

        $details->{text}  = $text_fn;
        $details->{title} = $t_name;

        push @{$result->{details}}, $details;

        $self->_add_output(
            {
                file    => $text_fn,
                content => $content
            });

        my $t = OpenQA::Parser::Result::Test->new(
            flags    => {},
            category => 'IPA',
            name     => $t_name,
            script   => undef,
            result   => $result->{result});
        $self->tests->add($t);
        $result->{test} = $t if $self->include_results();
        $self->_add_single_result($result);
    }

    $self;
}

{
    package OpenQA::Parser::Result::IPA::Info;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(distro platform image instance region results_file log_file timestamp)];
}

=head1 NAME

OpenQA::Parser::Format::IPA - IPA file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::IPA;

    my $parser = OpenQA::Parser::Format::IPA->new()->load('file.json');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p('IPA')->include_result(1)->load('file.json');

    my $parser = parser( IPA => 'file.json' );

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $extra_collection  = $parser->extra();

    my $info = $parser->extra()->first;  # Get system informations

    my $arrayref = $extra_collection->to_array;

    $parser->results->remove(0);

    my $passed_results = $parser->results->search( result => qr/ok/ );
    my $size = $passed_results->size;

=head1 DESCRIPTION

OpenQA::Parser::Format::IPA is the parser for the ipa file format.
The parser is making use of the C<tests()>, C<results()>, C<output()> and C<extra()> collections.

With the attribute C<include_result()> set to true, it will include inside the
results the respective test that generated it (inside the C<test()> attribute).
See also L<OpenQA::Parser::Result::OpenQA>.

The C<extra()> collection can include the environment of the tests shared among the results.
After the parsing, depending on the processed file, it should contain one element,
which is the environment.

    my $parser = parser( IPA => 'file.json' );

    my $environment = $parser->extra()->first;

Results objects are of specific type, as they are including additional attributes that are
supported only by the format (thus not by openQA).

=head1 ATTRIBUTES

OpenQA::Parser::Format::IPA inherits all attributes from L<OpenQA::Parser::Format::Base>.

=head1 METHODS

OpenQA::Parser::Format::IPA inherits all methods from L<OpenQA::Parser::Format::Base>, it only overrides
C<parse()> to generate a tree of results.

=cut

!!42;
