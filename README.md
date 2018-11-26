# Date::RetentionPolicy

This perl module selects a subset of a list of timestamps according
to rules that you specify, which is useful for pruning backups.

You can install the latest stable release of [this module on CPAN][1]

    cpanm Date::RetentionPolicy

and see the full documentation locally with

    perldoc Date::RetentionPolicy
    # or
    perldoc ./lib/Date/RetentionPolicy.pm

To build and install [this source code][2], use the [Dist::Zilla][3] tool:

    dzil --authordeps | cpanm
    dzil build
    cpanm ./Date-RetentionPolicy-$VERSION

[1] https://metacpan.org/pod/Date::RetentionPolicy
[2] https://github.com/IntelliTree/perl-Date-RetentionPolicy
[3] https://metacpan.org/pod/Dist::Zilla
