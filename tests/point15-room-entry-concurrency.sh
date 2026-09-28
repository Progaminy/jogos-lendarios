#!/usr/bin/env bash
set -euo pipefail

# Ponto 15 — testes reais de concorrência de entrada em salas.
# Requer uma base descartável/de teste em JL_TEST_DATABASE_URL.
# Nunca execute contra produção.
: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base de teste descartável.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -X -qAt)

cleanup() {
  "${PSQL[@]}" <<'SQL' >/dev/null 2>&1 || true
delete from public.ludo_rooms
where code in ('P15-CONCURRENT','P15-DOUBLE','P15-INVITE','P15-CHALLENGE');

delete from public.players
where phone in (
  '25899152501','25899152502','25899152503','25899152504',
  '25899152505','25899152506','25899152507','25899152508'
);
SQL
}
trap cleanup EXIT

cleanup

"${PSQL[@]}" <<'SQL'
insert into public.players(name,phone,pin_hash,balance)
values
 ('P15 Host Same','25899152501','point15',1000),
 ('P15 Entrant A','25899152502','point15',1000),
 ('P15 Entrant B','25899152503','point15',1000),
 ('P15 Host Double','25899152504','point15',1000),
 ('P15 Double','25899152505','point15',1000),
 ('P15 Host Invite','25899152506','point15',1000),
 ('P15 Host Challenge','25899152507','point15',1000),
 ('P15 Race','25899152508','point15',1000);

with p as (
  select phone,id from public.players where phone like '258991525%'
)
insert into public.ludo_rooms(code,host_id,player_count,mode,bet_amount,is_public,rules)
select 'P15-CONCURRENT',id,3,'solo',10,false,'{"safe_cells":true}'::jsonb from p where phone='25899152501'
union all
select 'P15-DOUBLE',id,2,'solo',10,false,'{"safe_cells":true}'::jsonb from p where phone='25899152504'
union all
select 'P15-INVITE',id,2,'solo',10,false,'{"safe_cells":true}'::jsonb from p where phone='25899152506'
union all
select 'P15-CHALLENGE',id,2,'solo',10,true,'{"safe_cells":true}'::jsonb from p where phone='25899152507';

insert into public.ludo_room_players(room_id,player_id,seat,color,status)
select r.id,p.id,1,'red','active'
from public.ludo_rooms r
join public.players p on
  (r.code='P15-CONCURRENT' and p.phone='25899152501') or
  (r.code='P15-DOUBLE' and p.phone='25899152504') or
  (r.code='P15-INVITE' and p.phone='25899152506') or
  (r.code='P15-CHALLENGE' and p.phone='25899152507');

select public.jl_ludo_ensure_code(id)
from public.players
where phone like '258991525%';

insert into public.player_sessions(player_id,token_hash,expires_at,last_seen_at)
select id,public.jl_token_hash('p15-race-token'),now()+interval '1 hour',now()
from public.players where phone='25899152508'
union all
select id,public.jl_token_hash('p15-challenge-host-token'),now()+interval '1 hour',now()
from public.players where phone='25899152507';

insert into public.ludo_invitations(room_id,invited_by,target_player_id,status)
select r.id,h.id,t.id,'pending'
from public.ludo_rooms r
join public.players h on h.phone='25899152506'
join public.players t on t.phone='25899152508'
where r.code='P15-INVITE';
SQL

room_same=$("${PSQL[@]}" -c "select id from public.ludo_rooms where code='P15-CONCURRENT'")
player_a=$("${PSQL[@]}" -c "select id from public.players where phone='25899152502'")
player_b=$("${PSQL[@]}" -c "select id from public.players where phone='25899152503'")

# 1) Dois jogadores entram na mesma sala ao mesmo tempo.
"${PSQL[@]}" -c "begin; select public.jl_ludo_join_room_internal('$room_same','$player_a'); select pg_sleep(0.35); commit;" >/tmp/p15-a.out 2>/tmp/p15-a.err &
pid1=$!
sleep 0.05
"${PSQL[@]}" -c "select public.jl_ludo_join_room_internal('$room_same','$player_b');" >/tmp/p15-b.out 2>/tmp/p15-b.err &
pid2=$!
wait "$pid1"
wait "$pid2"

same=$("${PSQL[@]}" -c "
select count(*)||':'||count(distinct seat)
from public.ludo_room_players
where room_id='$room_same' and status<>'left';
")
[[ "$same" == "3:3" ]] || { echo "FAIL same-room seats: $same"; exit 1; }

# 2) Duplo clique do mesmo jogador.
room_double=$("${PSQL[@]}" -c "select id from public.ludo_rooms where code='P15-DOUBLE'")
player_double=$("${PSQL[@]}" -c "select id from public.players where phone='25899152505'")

"${PSQL[@]}" -c "begin; select public.jl_ludo_join_room_internal('$room_double','$player_double'); select pg_sleep(0.35); commit;" >/tmp/p15-d1.out 2>/tmp/p15-d1.err &
pid1=$!
sleep 0.05
"${PSQL[@]}" -c "select public.jl_ludo_join_room_internal('$room_double','$player_double');" >/tmp/p15-d2.out 2>/tmp/p15-d2.err &
pid2=$!
wait "$pid1"
wait "$pid2"

double_rows=$("${PSQL[@]}" -c "
select count(*)
from public.ludo_room_players
where room_id='$room_double'
  and player_id='$player_double'
  and status<>'left';
")
[[ "$double_rows" == "1" ]] || { echo "FAIL double-click rows: $double_rows"; exit 1; }

# 3) Convite e desafio público simultâneos para o mesmo jogador.
invite_id=$("${PSQL[@]}" -c "
select i.id
from public.ludo_invitations i
join public.ludo_rooms r on r.id=i.room_id
where r.code='P15-INVITE'
  and i.status='pending'
limit 1;
")

"${PSQL[@]}" -c "begin; select public.jl_ludo_accept_invite('p15-race-token','$invite_id',true); select pg_sleep(0.35); commit;" >/tmp/p15-i.out 2>/tmp/p15-i.err &
pid1=$!
sleep 0.05
set +e
"${PSQL[@]}" -c "select public.jl_ludo_accept_public_challenge('p15-race-token','P15-CHALLENGE');" >/tmp/p15-c.out 2>/tmp/p15-c.err &
pid2=$!
wait "$pid1"
invite_rc=$?
wait "$pid2"
challenge_rc=$?
set -e

[[ "$invite_rc" == "0" ]] || { cat /tmp/p15-i.err; exit 1; }

race_player=$("${PSQL[@]}" -c "select id from public.players where phone='25899152508'")
active_rooms=$("${PSQL[@]}" -c "
select count(*)
from public.ludo_room_players rp
join public.ludo_rooms r on r.id=rp.room_id
where rp.player_id='$race_player'
  and rp.status<>'left'
  and r.status in ('waiting','negotiating','funding','playing');
")

[[ "$active_rooms" == "1" ]] || {
  echo "FAIL invite+challenge active rooms: $active_rooms"
  cat /tmp/p15-c.err
  exit 1
}

echo "PASS point15: same-room concurrency, double-click, invite+challenge race"
