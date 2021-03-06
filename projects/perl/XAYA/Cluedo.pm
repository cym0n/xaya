package XAYA::Cluedo;

use strict;
use v5.10;

use Moo;
use JSON::XS;
use DateTime;
use Data::Dumper;
extends 'XAYA::Game';

has name => (
    is => 'ro',
    default => 'Cluedo'
);

has game_status => (
    is => 'ro',
    default => sub { { players => []
                     } }
);

has rooms => (
    is => 'ro',
    default => sub { [ 'Kitchen', 'Conservatory', 'Dining Room', 'Ballroom', 'Study', 'Hall', 'Lounge', 'Library', 'Billiard Room' ] }
);
has weapons => (
    is => 'ro',
    default => sub { [ 'Candlestick', 'Dagger', 'Lead Pipe', 'Revolver', 'Rope', 'Monkey Wrench' ] }
);
has characters => (
    is => 'ro',
    default => sub { [ 'Mrs. White', 'Mr. Green', 'Mrs. Peacock', 'Professor Plum', 'Miss Scarlet', 'Colonel Mustard' ] }
);
has available_characters => (
    is => 'ro',
    default => sub { [] }
);

sub present_player
{
    my $self = shift;
    my $name = shift;
    my @player = grep {$_->{name} eq $name} @{$self->game_status->{players}};
    if(@player)
    {
        return $player[0];
    }
    else
    {
        return undef;
    }
}
sub busy_player
{
    my $self = shift;
    my $player = shift;
    if(exists $player->{ongoing} && 
       grep { $player->{ongoing}->{move}->{action} eq $_ } qw(move inspect))
    {
        return 1;
    }
    else
    {
        return 0;    
    }
}
sub inspectable_room
{
    my $self = shift;
    my $room = shift;
    my $ref = DateTime->now;
    $ref->add( hours => -6 );
    if( (! exists $self->game_status->{room_status}->{$room} || ! $self->game_status->{room_status}->{$room}) ||
        DateTime->compare($ref, $self->game_status->{room_status}->{$room}) > 0 )
    {
        for(@{$self->game_status->{players}})
        {
            my $p = $_;
            if($p->{position} eq $room &&
               $p->{ongoing} &&
               $p->{ongoing}->{move}->{action} eq 'inspect')
            {
                return 0;
            }
        }
        return 1;
    }
    else
    {
        return 0;
    }
}
sub add_knowledge
{
    my $self = shift;
    my $player = shift;
    my $card = shift;
    if(grep {$card eq $_} @{$player->{knowledge}})
    {
        return 0;
    }
    else
    {
        push @{$player->{knowledge}}, $card;
        return 1;
    }
}

sub process_notification
{
    my $self = shift;
    my $notification = shift;
    my $data = decode_json($notification->{payload});
    my $move_ok = 0;
    foreach my $move (@{$data->{moves}})
    {
        my $name = $move->{name};
        my $move = $move->{move};
        if(%{$move})
        {
            if($move->{action} eq 'join')
            {
                if(scalar @{$self->game_status->{players}} >= 6)
                {
                    $self->write_log($name, "No more players allowed");
                }
                elsif($self->present_player($name))
                {
                    $self->write_log($name, "Player already present");
                } 
                else
                {
                    my $character =  splice @{$self->available_characters}, rand @{$self->available_characters}, 1;
                    my @knowledge = @{$self->game_status->{knowledge}->{$character}};
                    push @{$self->game_status->{players}}, { name => $name,
                                                            character => $character,
                                                            knowledge => \@knowledge,
                                                            position => $self->rooms->[ rand @{$self->rooms} ] };
                    $move_ok = 1;
                }
            } 
            else
            {
                my $player = $self->present_player($name);
                if(! $player)
                {
                    $self->write_log($name, "Bad player");
                }
                elsif($self->busy_player($player))
                {
                    $self->write_log($name, "Busy player");
                }
                else
                {
                    if($move->{action} eq 'move')
                    {
                        my $destination = $move->{destination};
                        if($destination eq $player->{position})
                        {
                            $self->write_log($name, "Bad destination " . $move->{destination});
                        }
                        elsif(! grep { $_ eq $move->{destination} } @{$self->rooms})
                        {
                            $self->write_log($name, "Wrong destination " . $move->{destination});
                        }
                        else
                        {
                            $player->{ongoing} = { move => $move, timestamp => DateTime->now };    
                            $move_ok = 1;
                        }
                    }
                    elsif($move->{action} eq 'inspect')
                    {
                        if($self->inspectable_room($player->{position}))
                        {
                            $player->{ongoing} = { move => $move, timestamp => DateTime->now };    
                            $move_ok = 1;
                        }
                        else
                        {
                            $self->write_log($name, $player->{position} . " not available for inspection")
                        }
                    }
                }

            }
        }
    }
    $self->already_processed_notifications->{$notification->{topic} . $notification->{seq}} = 1;
    if($move_ok)
    {
        say Dumper($self->game_status) if (! $self->test);
    }
}

sub clock_activities
{
    my $self = shift;
    foreach my $p (@{$self->game_status->{players}})
    {
        if(exists $p->{ongoing} && $p->{ongoing})
        {
            my $ref = DateTime->now;
            $ref->add( hours => -1 );
            if(DateTime->compare($ref, $p->{ongoing}->{timestamp}) > 0)
            {
                my $move = $p->{ongoing}->{move};
                if($move->{action} eq 'move')
                {
                    $p->{position} = $move->{destination};
                }
                elsif($move->{action} eq 'inspect')
                {
                    my @clues = ( @{$self->game_status->{clues}->{rooms}},
                                  @{$self->game_status->{clues}->{characters}},
                                  @{$self->game_status->{clues}->{weapons}});
                    $self->add_knowledge($p, $clues[rand @clues]);
                    $self->game_status->{room_status}->{$p->{position}} = DateTime->now;
                }
                delete $p->{ongoing};
            } 
        }
    }
}

sub init
{
    my $self = shift;
    $self->SUPER::init();
    my @rooms = @{$self->rooms};
    my @weapons = @{$self->weapons};
    my @characters = @{$self->characters};
    @{$self->available_characters} = @characters;

    my $solution = {};
    my $index;

    $index = rand @rooms;
    $solution->{room} = $rooms[$index],
    splice @rooms, $index, 1;
    $index = rand @weapons;
    $solution->{weapon} = $weapons[$index],
    splice @weapons, $index, 1;
    $index = rand @characters;
    $solution->{character} = $characters[$index],
    splice @characters, $index, 1;
    $self->game_status->{solution} = $solution;

    @{$self->game_status->{clues}->{rooms}} = @rooms;
    @{$self->game_status->{clues}->{weapons}} = @weapons;
    @{$self->game_status->{clues}->{characters}} = @characters;

    my @clues = (@rooms, @weapons, @characters);
    for(@{$self->characters})
    {
        my $char = $_;
        my @knowledge = ();
        for(my $i = 0; $i < 3; $i++)
        {
            push @knowledge, splice( @clues, rand @clues, 1 );
        }
        $self->game_status->{knowledge}->{$char} = \@knowledge;
    }
    for(@{$self->rooms})
    {
        $self->game_status->{room_status}->{$_} = undef;
    }
    say Dumper($self->game_status) if (! $self->test); 

 
}


1;
