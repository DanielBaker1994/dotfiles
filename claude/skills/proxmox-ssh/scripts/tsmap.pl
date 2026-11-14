# Decode `tailscale debug netmap` (stdin) into "who may connect IN to this device".
# Usage (on a tailscale device): tailscale debug netmap | perl tsmap.pl
use JSON::PP; local $/; my $j = decode_json(<STDIN>);
binmode STDOUT, ':utf8';
my %ip;
for my $p (@{$j->{Peers} // []}) {
  (my $n = $p->{Name} // '') =~ s/\..*//;
  for (@{$p->{Addresses} // []}) { (my $a = $_) =~ s{/.*}{}; $ip{$a} = $n }
}
my $rules = $j->{PacketFilterRules} // $j->{PacketFilter} // [];
print "    (no inbound tailnet rules: nothing on the tailnet may connect)\n" unless @$rules;
for my $r (@$rules) {
  my %seen; my @s = grep { !$seen{$_}++ } map { my $x = $_; $x =~ s{/(32|128)$}{}; $ip{$x} // $x } @{$r->{SrcIPs} // []};
  @s = grep { !/^(100\.|fd7a:)/ } @s;   # drop the device's own addresses
  my %ps; my @d = grep { !$ps{$_}++ } map { my $p = $_->{Ports} // {}; (($p->{First}//0)==0 && ($p->{Last}//65535)==65535) ? '*' : ($p->{First}==$p->{Last} ? $p->{First} : "$p->{First}-$p->{Last}") } @{$r->{DstPorts} // []};
  printf "    from %s  ->  ports %s\n", join(', ', @s), join(',', @d);
}
