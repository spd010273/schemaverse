-- This was created by catting all the files in sqitch.plan into a single sql file and removing the transactions
-- Before running this you need to run:

-- CREATE ROLE schemaverse LOGIN NOINHERIT SUPERUSER CREATEDB CREATEROLE VALID UNTIL 'infinity';
-- CREATE DATABASE schemaverse OWNER=schemaverse;
CREATE GROUP players WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

CREATE SEQUENCE round_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;

CREATE SEQUENCE tic_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;

CREATE OR REPLACE FUNCTION generate_string(len integer)
  RETURNS character varying AS
$BODY$
BEGIN
	RETURN array_to_string(ARRAY(SELECT chr((65 + round(random() * 25)) :: integer) FROM generate_series(1,len)), '');
END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

CREATE TABLE player
(
  id integer NOT NULL,
  username character varying NOT NULL,
  password character(40) NOT NULL,
  created timestamp without time zone NOT NULL DEFAULT now(),
  balance bigint NOT NULL DEFAULT (10000)::numeric,
  fuel_reserve bigint DEFAULT 1000,
  error_channel character(10) NOT NULL DEFAULT lower((generate_string(10))::text),
  starting_fleet integer,
  symbol character(1),
  rgb character(6),
  CONSTRAINT player_pkey PRIMARY KEY (id),
  CONSTRAINT player_username_key UNIQUE (username),
  CONSTRAINT unq_symbol UNIQUE (symbol, rgb),
  CONSTRAINT ck_balance CHECK (balance::numeric >= 0::numeric),
  CONSTRAINT ck_fuel_reserve CHECK (fuel_reserve >= 0)
)
WITH (
  OIDS=FALSE
);

CREATE SEQUENCE player_id_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;

INSERT INTO player(id, username, password, fuel_reserve, balance) VALUES(0,'schemaverse','nopass',100000,100000); 

CREATE VIEW my_player AS 
	SELECT id, username, created, balance, fuel_reserve, password, error_channel, starting_fleet, symbol, rgb
	 FROM player WHERE username=SESSION_USER;

CREATE OR REPLACE RULE my_player_starting_fleet AS
    ON UPDATE TO my_player DO INSTEAD  
        UPDATE player SET starting_fleet = new.starting_fleet, symbol = new.symbol, rgb = new.rgb
             WHERE player.id = new.id;

CREATE TABLE variable
(
	name character varying NOT NULL,
	private boolean,
	numeric_value integer,
	char_value character varying,
	description TEXT,
	player_id integer NOT NULL DEFAULT 0 REFERENCES player(id), 
  	CONSTRAINT pk_variable PRIMARY KEY (name, player_id)
);

INSERT INTO variable VALUES 
	('MINE_BASE_FUEL','f',15,'','This value is used as a multiplier for fuel discovered from all planets'::TEXT,0),
	('UNIVERSE_CREATOR','t',9702000,'','The answer which creates the universe'::TEXT,0), 
	('EXPLODED','f',3,'','After this many tics, a ship will explode. Cost of a base ship will be returned to the player'::TEXT,0),
	('MAX_SHIPS','f',1000,'','The max number of ships a player can control at any time. Destroyed ships do not count'::TEXT,0),
	('MAX_SHIP_SKILL','f',500,'','This is the total amount of skill a ship can have (attack + defense + engineering + prospecting)'::TEXT,0),
	('MAX_SHIP_RANGE','f',5000,'','This is the maximum range a ship can have'::TEXT,0),
	('MAX_SHIP_FUEL','f',200000,'','This is the maximum fuel a ship can have'::TEXT,0),
	('MAX_SHIP_SPEED','f',800000,'','This is the maximum speed a ship can travel'::TEXT,0),
	('MAX_SHIP_HEALTH','f',1000,'','This is the maximum health a ship can have'::TEXT,0),
	('ROUND_START_DATE','f',0,'1986-03-27','The day the round started.'::TEXT,0),
	('ROUND_LENGTH','f',0,'1 days','The length of time a round takes to complete'::TEXT,0),
	('DEFENSE_EFFICIENCY', 'f', 50, '', 'Used to calculate attack with defense'::TEXT,0);

CREATE TABLE price_list
(
	code character varying NOT NULL PRIMARY KEY,
	cost integer NOT NULL,
	description TEXT
);

INSERT INTO price_list VALUES
	('SHIP', 1000, 'HOLY CRAP. A NEW SHIP!'),
	('FLEET_RUNTIME', 10000000, 'Add one minute of runtime to a fleet script'),
	('MAX_HEALTH', 50, 'Increases a ships MAX_HEALTH by one'),
	('MAX_FUEL', 1, 'Increases a ships MAX_FUEL by one'),
	('MAX_SPEED', 1, 'Increases a ships MAX_SPEED by one'),
	('RANGE', 25, 'Increases a ships RANGE by one'),
	('ATTACK', 25,'Increases a ships ATTACK by one'),
	('DEFENSE', 25, 'Increases a ships DEFENSE by one'),
	('ENGINEERING', 25, 'Increases a ships ENGINEERING by one'),
	('PROSPECTING', 25, 'Increases a ships PROSPECTING by one');

CREATE OR REPLACE FUNCTION GET_PLAYER_ID(check_username name) RETURNS integer AS $get_player_id$
	SELECT id FROM public.player WHERE username=$1;
$get_player_id$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE VIEW public_variable AS SELECT * FROM variable WHERE (private='f' AND player_id=0) OR player_id=GET_PLAYER_ID(SESSION_USER);

CREATE OR REPLACE RULE public_variable_delete AS
     ON DELETE TO public_variable DO INSTEAD  
         DELETE FROM variable WHERE variable.name::text = old.name::text AND variable.player_id = get_player_id(SESSION_USER);

CREATE OR REPLACE RULE public_variable_insert AS
    ON INSERT TO public_variable DO INSTEAD  
        INSERT INTO variable (name, char_value, numeric_value, description, player_id) 
            VALUES (new.name, new.char_value, new.numeric_value, new.description, get_player_id(SESSION_USER));

CREATE OR REPLACE RULE public_variable_update AS
    ON UPDATE TO public_variable DO INSTEAD  
        UPDATE variable SET numeric_value = new.numeric_value, description = new.description
            WHERE variable.name::text = new.name::text AND variable.player_id = get_player_id(SESSION_USER);

CREATE OR REPLACE FUNCTION GET_NUMERIC_VARIABLE(variable_name character varying) RETURNS integer AS $get_numeric_variable$
DECLARE
	value integer;
BEGIN
	IF CURRENT_USER = 'schemaverse' THEN
		SELECT numeric_value INTO value FROM variable WHERE name = variable_name and player_id=0;
	ELSE 
		SELECT numeric_value INTO value FROM public_variable WHERE name = variable_name;
	END IF;
	RETURN value; 
END $get_numeric_variable$  LANGUAGE plpgsql;







CREATE OR REPLACE FUNCTION GET_CHAR_VARIABLE(variable_name character varying) RETURNS character varying AS $get_char_variable$
DECLARE
	value character varying;
BEGIN
	IF CURRENT_USER = 'schemaverse' THEN
		SELECT char_value INTO value FROM variable WHERE name = variable_name and player_id=0;
	ELSE
		SELECT char_value INTO value FROM public_variable WHERE name = variable_name;
	END IF;
	RETURN value; 
END $get_char_variable$  LANGUAGE plpgsql;







CREATE OR REPLACE FUNCTION SET_NUMERIC_VARIABLE(variable_name character varying, new_value integer) RETURNS integer AS $set_numeric_variable$
BEGIN
	SET search_path to public;
	IF (SELECT count(*) FROM variable WHERE name=variable_name AND player_id=GET_PLAYER_ID(SESSION_USER)) = 1 THEN
		UPDATE variable SET numeric_value=new_value WHERE  name=variable_name AND player_id=GET_PLAYER_ID(SESSION_USER);
	ELSEIF (SELECT count(*) FROM variable WHERE name=variable_name AND player_id=0) = 1 THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Cannot update a system variable'';';
	ELSE 
		INSERT INTO variable VALUES(variable_name,'f',new_value,'','',GET_PLAYER_ID(SESSION_USER));
	END IF;
	RETURN new_value; 
END $set_numeric_variable$ SECURITY definer LANGUAGE plpgsql ;








CREATE OR REPLACE FUNCTION SET_CHAR_VARIABLE(variable_name character varying, new_value character varying) RETURNS character varying AS 
$set_char_variable$
BEGIN
	SET search_path to public;
        IF (SELECT count(*) FROM variable WHERE name=variable_name AND player_id=GET_PLAYER_ID(SESSION_USER)) = 1 THEN
                UPDATE variable SET char_value=new_value WHERE  name=variable_name AND player_id=GET_PLAYER_ID(SESSION_USER);
        ELSEIF (SELECT count(*) FROM variable WHERE name=variable_name AND player_id=0) = 1 THEN
                EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Cannot update a system variable'';';
        ELSE
                INSERT INTO variable VALUES(variable_name,'f',0,new_value,'',GET_PLAYER_ID(SESSION_USER));
        END IF;

        RETURN new_value;
END $set_char_variable$ SECURITY definer LANGUAGE plpgsql;







CREATE OR REPLACE FUNCTION variable_insert()
  RETURNS trigger AS
$BODY$
        BEGIN
        IF (SELECT count(*) FROM variable WHERE player_id=0 and name=NEW.name) = 1 THEN
                RETURN OLD;
        ELSE
               RETURN NEW;
        END IF;
END $BODY$
  LANGUAGE plpgsql VOLATILE;


CREATE TRIGGER VARIABLE_INSERT BEFORE INSERT ON variable
  FOR EACH ROW EXECUTE PROCEDURE VARIABLE_INSERT();






CREATE VIEW online_players AS
	SELECT id, username FROM player
		WHERE username in (SELECT DISTINCT usename FROM pg_stat_activity);








CREATE OR REPLACE FUNCTION player_creation()
  RETURNS trigger AS
$BODY$
DECLARE 
	new_planet RECORD;
BEGIN
	execute 'CREATE ROLE ' || NEW.username || ' WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE ENCRYPTED PASSWORD '''|| NEW.password ||'''  IN GROUP players'; 

	IF (SELECT count(*) FROM planets WHERE conqueror_id IS NULL) > 0 THEN
		UPDATE planet SET conqueror_id=NEW.id, mine_limit=50, fuel=3000000, difficulty=10 
			WHERE planet.id = 
				(SELECT id FROM planet WHERE conqueror_id is null ORDER BY RANDOM() LIMIT 1);
	ELSE
		FOR new_planet IN SELECT
			nextval('planet_id_seq') as id,
			CASE (RANDOM() * 11)::integer % 12
			WHEN 0 THEN 'Aethra_' || generate_series
                         WHEN 1 THEN 'Mony_' || generate_series
                         WHEN 2 THEN 'Semper_' || generate_series
                         WHEN 3 THEN 'Voit_' || generate_series
                         WHEN 4 THEN 'Lester_' || generate_series 
                         WHEN 5 THEN 'Rio_' || generate_series 
                         WHEN 6 THEN 'Zergon_' || generate_series 
                         WHEN 7 THEN 'Cannibalon_' || generate_series
                         WHEN 8 THEN 'Omicron Persei_' || generate_series
                         WHEN 9 THEN 'Urectum_' || generate_series
                         WHEN 10 THEN 'Wormulon_' || generate_series
                         WHEN 11 THEN 'Kepler_' || generate_series
			END as name,
                50 as mine_limit,
                3000000 as fuel,
                10 as difficulty,
		point(
                CASE (RANDOM() * 1)::integer % 2
                        WHEN 0 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR'))::integer 
                        WHEN 1 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR') * -1)::integer
		END,
                CASE (RANDOM() * 1)::integer % 2
                        WHEN 0 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR'))::integer
                        WHEN 1 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR') * -1)::integer		
		END) as location
		FROM generate_series(1,10)
		LOOP
			if not exists (select 1 from planet where (location <-> new_planet.location) <= 3000) then
				INSERT INTO planet(id, name, mine_limit, difficulty, fuel, location, location_x, location_y, conqueror_id)
					VALUES(new_planet.id, new_planet.name, new_planet.mine_limit, new_planet.difficulty, new_planet.fuel, new_planet.location,new_planet.location[0],new_planet.location[1], NEW.id);
				Exit;
			END IF;	
		END LOOP;
	END IF;

	INSERT INTO player_round_stats(player_id, round_id) VALUES (NEW.id, (select last_value from round_seq));
	INSERT INTO player_overall_stats(player_id) VALUES (NEW.id);



RETURN NEW;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE TRIGGER player_creation
  AFTER INSERT
  ON player
  FOR EACH ROW
  EXECUTE PROCEDURE player_creation();








CREATE OR REPLACE FUNCTION get_player_username(check_player_id integer)
  RETURNS character varying AS
$BODY$
	SELECT username FROM public.player WHERE id=$1;
$BODY$
  LANGUAGE sql STABLE SECURITY DEFINER
  COST 100;







CREATE OR REPLACE FUNCTION get_player_error_channel(player_name character varying DEFAULT SESSION_USER)
  RETURNS character varying AS
$BODY$
DECLARE 
	found_error_channel character varying;
BEGIN
	IF CURRENT_USER = 'schemaverse' THEN
		SELECT error_channel INTO found_error_channel FROM player WHERE username=player_name;
        ELSE
		SELECT error_channel INTO found_error_channel FROM my_player LIMIT 1;
	END IF;
	RETURN found_error_channel;
END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;








CREATE OR REPLACE FUNCTION charge(price_code character varying, quantity bigint)
  RETURNS boolean AS
$BODY$
DECLARE 
	amount bigint;
	current_balance bigint;
BEGIN
	SET search_path to public;

	SELECT cost INTO amount FROM price_list WHERE code=UPPER(price_code);
	SELECT balance INTO current_balance FROM player WHERE username=SESSION_USER;
	IF quantity < 0 OR (current_balance - (amount * quantity)) < 0 THEN
		RETURN 'f';
	ELSE 
		UPDATE player SET balance=(balance-(amount * quantity)) WHERE username=SESSION_USER;
	END IF;
	RETURN 't'; 
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;








CREATE TABLE ship
(
  id integer NOT NULL,
  player_id integer NOT NULL DEFAULT get_player_id(SESSION_USER),
  fleet_id integer,
  name character varying,
  last_action_tic integer DEFAULT 0,
  last_move_tic integer DEFAULT 0,
  last_living_tic integer DEFAULT 0,
  current_health integer NOT NULL DEFAULT 100,
  max_health integer NOT NULL DEFAULT 100,
  future_health integer DEFAULT 100,
  current_fuel integer NOT NULL DEFAULT 1100,
  max_fuel integer NOT NULL DEFAULT 1100,
  max_speed integer NOT NULL DEFAULT 1000,
  range integer NOT NULL DEFAULT 300,
  attack integer NOT NULL DEFAULT 5,
  defense integer NOT NULL DEFAULT 5,
  engineering integer NOT NULL DEFAULT 5,
  prospecting integer NOT NULL DEFAULT 5,
  location_x integer NOT NULL DEFAULT 0,
  location_y integer NOT NULL DEFAULT 0,
  destroyed boolean NOT NULL DEFAULT false,
  location point,
  CONSTRAINT ship_pkey PRIMARY KEY (id),
  CONSTRAINT ship_player_id_fkey FOREIGN KEY (player_id)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT ship_check CHECK (current_health <= max_health),
  CONSTRAINT ship_check1 CHECK (current_fuel <= max_fuel)
);







CREATE OR REPLACE FUNCTION get_ship_name(ship_id integer)
  RETURNS character varying AS
$BODY$
DECLARE 
	found_shipname character varying;
BEGIN
	SET search_path to public;
	SELECT name INTO found_shipname FROM ship WHERE id=ship_id;
	RETURN found_shipname;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;







CREATE TABLE ship_control
(
  ship_id integer NOT NULL,
  speed integer NOT NULL DEFAULT 0,
  direction integer NOT NULL DEFAULT 0,
  destination_x integer,
  destination_y integer,
  repair_priority integer DEFAULT 0,
  action character(30),
  action_target_id integer,
  destination point,
  target_speed integer,
  target_direction integer,
  player_id integer,
  CONSTRAINT ship_control_pkey PRIMARY KEY (ship_id),
  CONSTRAINT ship_control_player_id FOREIGN KEY (player_id)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT ship_control_ship_id_fkey FOREIGN KEY (ship_id)
      REFERENCES ship (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT ch_action CHECK (action = ANY (ARRAY['REPAIR'::bpchar, 'ATTACK'::bpchar, 'MINE'::bpchar])),
  CONSTRAINT ship_control_direction_check CHECK (0 <= direction AND direction <= 360)
);







CREATE SEQUENCE ship_id_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;







CREATE TABLE ship_flight_recorder
(
  ship_id integer NOT NULL,
  tic integer NOT NULL,
  location_x integer,
  location_y integer,
  location point,
  player_id integer,
  CONSTRAINT ship_flight_recorder_pkey PRIMARY KEY (ship_id, tic),
  CONSTRAINT ship_flight_recorder_ship_id_fkey FOREIGN KEY (ship_id)
      REFERENCES ship (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE CASCADE
);







CREATE OR REPLACE VIEW my_ships_flight_recorder AS 
 WITH current_player AS (
         SELECT get_player_id("session_user"()) AS player_id
        )
 SELECT ship_flight_recorder.ship_id, ship_flight_recorder.tic, 
    ship_flight_recorder.location, 
    ship_flight_recorder.location[0] AS location_x, 
    ship_flight_recorder.location[1] AS location_y
   FROM ship_flight_recorder, current_player
  WHERE ship_flight_recorder.player_id = current_player.player_id;







CREATE OR REPLACE VIEW ships_in_range AS 
 SELECT enemies.id, players.id AS ship_in_range_of, enemies.player_id, 
    enemies.name, 
    enemies.current_health::numeric / enemies.max_health::numeric AS health, 
    enemies.location AS enemy_location
   FROM ship enemies, ship players
  WHERE players.player_id = get_player_id("session_user"()) AND enemies.player_id <> players.player_id AND NOT enemies.destroyed AND NOT players.destroyed 
 AND circle(players.location, players.range::double precision) @> circle(enemies.location, 1::double precision);










CREATE OR REPLACE VIEW my_ships AS 
 SELECT ship.id, ship.fleet_id, ship.player_id, ship.name, ship.last_action_tic, 
    ship.last_move_tic, ship.last_living_tic, ship.current_health, 
    ship.max_health, ship.current_fuel, ship.max_fuel, ship.max_speed, 
    ship.range, ship.attack, ship.defense, ship.engineering, ship.prospecting, 
    ship.location_x, ship.location_y, ship_control.direction, 
    ship_control.speed, ship_control.destination_x, ship_control.destination_y, 
    ship_control.repair_priority, ship_control.action, 
    ship_control.action_target_id, ship.location, ship_control.destination, 
    ship_control.target_speed, ship_control.target_direction
   FROM ship, ship_control
  WHERE ship.player_id = get_player_id("session_user"()) AND ship.id = ship_control.ship_id AND ship.destroyed = false;


CREATE OR REPLACE RULE ship_control_update AS
    ON UPDATE TO my_ships DO INSTEAD ( UPDATE ship_control SET target_speed = new.target_speed, target_direction = new.target_direction, destination_x = COALESCE(new.destination_x::double precision, new.destination[0]), 
destination_y = COALESCE(new.destination_y::double precision, new.destination[1]), destination = COALESCE(new.destination, point(new.destination_x::double precision, new.destination_y::double precision)), repair_priority = 
new.repair_priority, action = new.action, action_target_id = new.action_target_id
  WHERE ship_control.ship_id = new.id;
 UPDATE ship SET name = new.name, fleet_id = new.fleet_id
  WHERE ship.id = new.id;
);


CREATE OR REPLACE RULE ship_delete AS
    ON DELETE TO my_ships DO INSTEAD  UPDATE ship SET destroyed = true
  WHERE ship.id = old.id AND ship.player_id = get_player_id("session_user"());


CREATE OR REPLACE RULE ship_insert AS
    ON INSERT TO my_ships DO INSTEAD  INSERT INTO ship (name, range, attack, defense, engineering, prospecting, location_x, location_y, location, last_living_tic, fleet_id) 
  VALUES (new.name, COALESCE(new.range, 300), COALESCE(new.attack, 5), COALESCE(new.defense, 5), COALESCE(new.engineering, 5), COALESCE(new.prospecting, 5), COALESCE(new.location_x::double precision, new.location[0]), 
COALESCE(new.location_y::double precision, new.location[1]), COALESCE(new.location, point(new.location_x::double precision, new.location_y::double precision)), (( SELECT tic_seq.last_value
           FROM tic_seq)), COALESCE(new.fleet_id, NULL::integer))
  RETURNING ship.id, ship.fleet_id, ship.player_id, ship.name, 
    ship.last_action_tic, ship.last_move_tic, ship.last_living_tic, 
    ship.current_health, ship.max_health, ship.current_fuel, ship.max_fuel, 
    ship.max_speed, ship.range, ship.attack, ship.defense, ship.engineering, 
    ship.prospecting, ship.location_x, ship.location_y, 0, 0, 0, 0, 0, 
    ''::character(30) AS bpchar, 0, ship.location, ship.location, 0, 0;








CREATE OR REPLACE FUNCTION create_ship()
  RETURNS trigger AS
$BODY$
BEGIN
	--CHECK SHIP STATS
	NEW.current_health = 100; 
	NEW.max_health = 100;
	NEW.current_fuel = 100; 
	NEW.max_fuel = 100;
	NEW.max_speed = 1000;

	IF ((SELECT COUNT(*) FROM ship WHERE player_id=NEW.player_id AND NOT destroyed) > 2000 ) THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''A player can only have 2000 ships in their fleet for this round'';';
		RETURN NULL;
	END IF; 

	IF (LEAST(NEW.attack, NEW.defense, NEW.engineering, NEW.prospecting) < 0 ) THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''When creating a new ship, Attack Defense Engineering and Prospecting cannot be values lower than zero'';';
		RETURN NULL;
	END IF; 

	IF (NEW.attack + NEW.defense + NEW.engineering + NEW.prospecting) > 20 THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''When creating a new ship, the following must be true (Attack + Defense + Engineering + Prospecting) > 20'';';
		RETURN NULL;
	END IF; 

	
	--Backwards compatibility
	IF NEW.location IS NULL THEN
		NEW.location := POINT(NEW.location_x, NEW.location_y);
	ELSE
		NEW.location_x := NEW.location[0];
		NEW.location_y := NEW.location[1];
	END IF;
	
	IF not exists (select 1 from planets p where p.location ~= NEW.location and p.conqueror_id = NEW.player_id) then
		SELECT location INTO NEW.location from planets where conqueror_id=NEW.player_id limit 1;
		NEW.location_x := NEW.location[0];
		NEW.location_y := NEW.location[1];
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''New ship MUST be created on a planet your player has conquered'';';
		--RETURN NULL;
	END IF;

	IF NEW.location is null THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Lost all your planets. Unable to create new ships.'';';
		RETURN NULL;
	END IF;
	--CHARGE ACCOUNT	
	IF NOT CHARGE('SHIP', 1) THEN 
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to purchase ship'';';
		RETURN NULL;
	END IF;

	NEW.last_move_tic := (SELECT last_value FROM tic_seq); 


	RETURN NEW; 
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;

CREATE TRIGGER CREATE_SHIP BEFORE INSERT ON ship
  FOR EACH ROW EXECUTE PROCEDURE CREATE_SHIP(); 







CREATE OR REPLACE FUNCTION create_ship_event()
  RETURNS trigger AS
$BODY$
BEGIN
	INSERT INTO ship_flight_recorder(ship_id, tic, location, player_id) VALUES(NEW.id, (SELECT last_value FROM tic_seq)-1, NEW.location, NEW.player_id);

	INSERT INTO event(action, player_id_1, ship_id_1, location, public, tic)
		VALUES('BUY_SHIP',NEW.player_id, NEW.id, NEW.location, 'f',(SELECT last_value FROM tic_seq));
	RETURN NULL; 
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;

CREATE TRIGGER create_ship_event
  AFTER INSERT
  ON ship
  FOR EACH ROW
  EXECUTE PROCEDURE create_ship_event();







CREATE OR REPLACE FUNCTION destroy_ship()
  RETURNS trigger AS
$BODY$
BEGIN
	IF ( NOT OLD.destroyed = NEW.destroyed ) AND NEW.destroyed='t' THEN
	        UPDATE player SET balance=balance+(select cost from price_list where code='SHIP') WHERE id=OLD.player_id;
		
		delete from ships_near_planets where ship = NEW.id;
	   	delete from ships_near_ships where first_ship = NEW.id;
	   	delete from ships_near_ships where second_ship = NEW.id;

		INSERT INTO event(action, player_id_1, ship_id_1, location, public, tic)
			VALUES('EXPLODE',NEW.player_id, NEW.id, NEW.location, 't',(SELECT last_value FROM tic_seq));

	END IF;
	RETURN NULL;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE TRIGGER destroy_ship
  AFTER UPDATE
  ON ship
  FOR EACH ROW
  EXECUTE PROCEDURE destroy_ship();








CREATE OR REPLACE FUNCTION create_ship_controller()
  RETURNS trigger AS
$BODY$
BEGIN
	INSERT INTO ship_control(ship_id, player_id) VALUES(NEW.id, NEW.player_id);
	RETURN NEW;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE TRIGGER create_ship_controller
  AFTER INSERT
  ON ship
  FOR EACH ROW
  EXECUTE PROCEDURE create_ship_controller();








CREATE OR REPLACE FUNCTION ship_move_update()
  RETURNS trigger AS
$BODY$
BEGIN
  IF NOT NEW.location ~= OLD.location THEN
    INSERT INTO ship_flight_recorder(ship_id, tic, location, player_id) VALUES(NEW.id, (SELECT last_value FROM tic_seq), NEW.location, NEW.player_id);
  END IF;
  RETURN NULL;
END $BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE TRIGGER ship_move_update
  AFTER UPDATE
  ON ship
  FOR EACH ROW
  EXECUTE PROCEDURE ship_move_update();








CREATE TABLE fleet
(
  id integer NOT NULL,
  player_id integer NOT NULL DEFAULT get_player_id("session_user"()),
  name character varying(50),
  script text DEFAULT 'Select 1;'::text,
  script_declarations text DEFAULT 'fakevar smallint;'::text,
  last_script_update_tic integer DEFAULT 0,
  enabled boolean NOT NULL DEFAULT false,
  runtime interval DEFAULT '00:00:00'::interval,
  CONSTRAINT fleet_pkey PRIMARY KEY (id),
  CONSTRAINT fleet_player_id_fkey FOREIGN KEY (player_id)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION
);








CREATE SEQUENCE fleet_id_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;








CREATE OR REPLACE VIEW my_fleets AS 
	SELECT fleet.id, fleet.name, fleet.script, fleet.script_declarations, fleet.last_script_update_tic, fleet.enabled, fleet.runtime
			FROM fleet
			WHERE fleet.player_id = get_player_id("session_user"());


CREATE OR REPLACE RULE fleet_insert AS
    ON INSERT TO my_fleets DO INSTEAD  INSERT INTO fleet (player_id, name) 
  VALUES (get_player_id("session_user"()), new.name);


CREATE OR REPLACE RULE fleet_update AS
    ON UPDATE TO my_fleets DO INSTEAD  UPDATE fleet SET name = new.name, script = new.script, script_declarations = new.script_declarations, enabled = new.enabled
  WHERE fleet.id = new.id;









CREATE OR REPLACE FUNCTION disable_fleet(fleet_id integer)
  RETURNS boolean AS
$BODY$
DECLARE
BEGIN
	IF CURRENT_USER = 'schemaverse' THEN
		UPDATE fleet SET enabled='f' WHERE id=fleet_id;
	ELSE 
		UPDATE fleet SET enabled='f' WHERE id=fleet_id  AND player_id=GET_PLAYER_ID(SESSION_USER);
	END IF;
	RETURN 't'; 
END $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;








CREATE OR REPLACE FUNCTION get_fleet_runtime(fleet_id integer, username character varying)
  RETURNS interval AS
$BODY$
DECLARE
	fleet_runtime interval;
BEGIN
	SET search_path to public;
	SELECT runtime INTO fleet_runtime FROM fleet WHERE id=fleet_id AND (GET_PLAYER_ID(username)=player_id);
	RETURN fleet_runtime;
END 
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;








CREATE OR REPLACE FUNCTION fleet_script_update()
  RETURNS trigger AS
$BODY$
DECLARE
	player_username character varying;
	secret character varying;
	current_tic integer;
BEGIN
	IF ((NEW.script = OLD.script) AND (NEW.script_declarations = OLD.script_declarations)) THEN
		RETURN NEW;
	END IF;

	SELECT last_value INTO current_tic FROM tic_seq;


	IF NEW.script LIKE '%$fleet_script_%' OR  NEW.script_declarations LIKE '%$fleet_script_%' THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''TILT!'';';
		RETURN NEW;
	END IF;

	IF NEW.last_script_update_tic = current_tic THEN
		NEW.script := OLD.script;
		NEW.script_declarations := OLD.script_declarations;
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Fleet scripts can only be updated once a tic. While you wait why not brush up on your PL/pgSQL skills? '';';
		RETURN NEW;
	END IF;

	NEW.last_script_update_tic := current_tic;

	--secret to stop SQL injections here
	secret := 'fleet_script_' || (RANDOM()*1000000)::integer;
	EXECUTE 'CREATE OR REPLACE FUNCTION FLEET_SCRIPT_'|| NEW.id ||'() RETURNS boolean as $'||secret||'$
	DECLARE
		this_fleet_id integer;
		this_fleet_script_start timestamptz;
		' || NEW.script_declarations || '
	BEGIN
		this_fleet_script_start := current_timestamp;
		this_fleet_id := '|| NEW.id||';
		' || NEW.script || '
	RETURN 1;
	END $'||secret||'$ LANGUAGE plpgsql;'::TEXT;
	
	SELECT GET_PLAYER_USERNAME(player_id) INTO player_username FROM fleet WHERE id=NEW.id;
	EXECUTE 'REVOKE ALL ON FUNCTION FLEET_SCRIPT_'|| NEW.id ||'() FROM PUBLIC'::TEXT;
	EXECUTE 'REVOKE ALL ON FUNCTION FLEET_SCRIPT_'|| NEW.id ||'() FROM players'::TEXT;
	EXECUTE 'GRANT EXECUTE ON FUNCTION FLEET_SCRIPT_'|| NEW.id ||'() TO '|| player_username ||''::TEXT;
	
	RETURN NEW;
END $BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;

CREATE TRIGGER FLEET_SCRIPT_UPDATE BEFORE UPDATE ON fleet
  FOR EACH ROW EXECUTE PROCEDURE FLEET_SCRIPT_UPDATE();  








CREATE OR REPLACE FUNCTION refuel_ship(ship_id integer)
  RETURNS integer AS
$BODY$
DECLARE
	current_fuel_reserve bigint;
	new_fuel_reserve bigint;
	
	current_ship_fuel bigint;
	new_ship_fuel bigint;
	
	max_ship_fuel bigint;
BEGIN
	SET search_path to public;

	SELECT fuel_reserve INTO current_fuel_reserve FROM player WHERE username=SESSION_USER;
	SELECT current_fuel, max_fuel INTO current_ship_fuel, max_ship_fuel FROM ship WHERE id=ship_id;

	
	new_fuel_reserve = current_fuel_reserve - (max_ship_fuel - current_ship_fuel);
	IF new_fuel_reserve < 0 THEN
		new_ship_fuel = max_ship_fuel - (@new_fuel_reserve);
		new_fuel_reserve = 0;
	ELSE
		new_ship_fuel = max_ship_fuel;
	END IF;
	
	UPDATE ship SET current_fuel=new_ship_fuel WHERE id=ship_id;
	UPDATE player SET fuel_reserve=new_fuel_reserve WHERE username=SESSION_USER;

	INSERT INTO event(action, player_id_1, ship_id_1, descriptor_numeric, public, tic)
		VALUES('REFUEL_SHIP',GET_PLAYER_ID(SESSION_USER), ship_id , new_ship_fuel, 'f',(SELECT last_value FROM tic_seq));

	RETURN new_ship_fuel;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;










CREATE OR REPLACE FUNCTION upgrade(reference_id integer, code character varying, quantity integer)
  RETURNS boolean AS
$BODY$
DECLARE 

	ship_value integer;
	
BEGIN
	SET search_path to public;
	IF code = 'SHIP' THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''You cant upgrade ship into ship..Try to insert in my_ships'';';
		RETURN FALSE;
	END IF;
	IF code = 'FLEET_RUNTIME' THEN

		IF (SELECT sum(runtime) FROM fleet WHERE player_id=GET_PLAYER_ID(SESSION_USER)) > '0 minutes'::interval THEN
			IF NOT CHARGE(code, quantity) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to increase fleet runtime'';';
				RETURN FALSE;
			END IF;
		ELSEIF quantity > 1 THEN
			IF NOT CHARGE(code, quantity-1) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to increase fleet runtime'';';
				RETURN FALSE;
			END IF;
		END IF;
	
		UPDATE fleet SET runtime=runtime + (quantity || ' minute')::interval where id=reference_id;

		INSERT INTO event(action, player_id_1, referencing_id, public, tic)
			VALUES('FLEET',GET_PLAYER_ID(SESSION_USER), reference_id , 'f',(SELECT last_value FROM tic_seq));
		RETURN TRUE;

	END IF;

	IF code = 'REFUEL' THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Please use REFUEL_SHIP(ship_id) to refuel a ship now.'';';
		RETURN FALSE;

	END IF;


	IF code = 'RANGE' THEN
		SELECT range INTO ship_value FROM ship WHERE id=reference_id;
		IF (ship_value + quantity) > GET_NUMERIC_VARIABLE('MAX_SHIP_RANGE') THEN
			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''The range of a ship cannot exceed the MAX_SHIP_RANGE system value of '|| GET_NUMERIC_VARIABLE('MAX_SHIP_RANGE')||''';';
			RETURN FALSE;
		ELSE
			IF NOT CHARGE(code, quantity) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to perform upgrade'';';
				RETURN FALSE;
			END IF;			
			UPDATE ship SET range=(range+quantity) WHERE id=reference_id ;
		END IF;
	ELSEIF code = 'MAX_SPEED' THEN
		SELECT max_speed INTO ship_value FROM ship WHERE id=reference_id;
		IF (ship_value + quantity) > GET_NUMERIC_VARIABLE('MAX_SHIP_SPEED') THEN
			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''The max speed of a ship cannot exceed the MAX_SHIP_SPEED system value of '|| GET_NUMERIC_VARIABLE('MAX_SHIP_SPEED')||''';';
			RETURN FALSE;
		ELSE
			IF NOT CHARGE(code, quantity) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to perform upgrade'';';
				RETURN FALSE;
			END IF;			
			UPDATE ship SET max_speed=(max_speed+quantity) WHERE id=reference_id ;
		END IF;
	ELSEIF code = 'MAX_HEALTH' THEN
		SELECT max_health INTO ship_value FROM ship WHERE id=reference_id;
		IF (ship_value + quantity) > GET_NUMERIC_VARIABLE('MAX_SHIP_HEALTH') THEN
			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''The max health of a ship cannot exceed the MAX_SHIP_HEALTH system value of '|| GET_NUMERIC_VARIABLE('MAX_SHIP_HEALTH')||''';';
			RETURN FALSE;
		ELSE
			IF NOT CHARGE(code, quantity) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to perform upgrade'';';
				RETURN FALSE;
			END IF;	
			UPDATE ship SET max_health=(max_health+quantity) WHERE id=reference_id ;
		END IF;
	ELSEIF code = 'MAX_FUEL' THEN
		SELECT max_fuel INTO ship_value FROM ship WHERE id=reference_id;
		IF (ship_value + quantity) > GET_NUMERIC_VARIABLE('MAX_SHIP_FUEL') THEN
			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''The max fuel of a ship cannot exceed the MAX_SHIP_FUEL system value of '|| GET_NUMERIC_VARIABLE('MAX_SHIP_FUEL')||''';';
			RETURN FALSE;
		ELSE
			IF NOT CHARGE(code, quantity) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to perform upgrade'';';
				RETURN FALSE;
			END IF;	
			UPDATE ship SET max_fuel=(max_fuel+quantity) WHERE id=reference_id ;
		END IF;
	ELSE
		SELECT (attack+defense+prospecting+engineering) INTO ship_value FROM ship WHERE id=reference_id;
		IF (ship_value + quantity) > GET_NUMERIC_VARIABLE('MAX_SHIP_SKILL') THEN
			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''The total skill of a ship cannot exceed the MAX_SHIP_SKILL system value of '|| GET_NUMERIC_VARIABLE('MAX_SHIP_SKILL')||''';';
			RETURN FALSE;
		ELSE
			IF NOT CHARGE(code, quantity) THEN
				EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Not enough funds to perform upgrade'';';
				RETURN FALSE;
			END IF;		
			IF code = 'ATTACK' THEN
				UPDATE ship SET attack=(attack+quantity) WHERE id=reference_id ;
			ELSEIF code = 'DEFENSE' THEN
				UPDATE ship SET defense=(defense+quantity) WHERE id=reference_id ;
			ELSEIF code = 'PROSPECTING' THEN
				UPDATE ship SET prospecting=(prospecting+quantity) WHERE id=reference_id ;
			ELSEIF code = 'ENGINEERING' THEN
				UPDATE ship SET engineering=(engineering+quantity) WHERE id=reference_id ;	
			END IF;
		END IF;
	
	END IF;	

	INSERT INTO event(action, player_id_1, ship_id_1, descriptor_numeric,descriptor_string, public, tic)
	VALUES('UPGRADE_SHIP',GET_PLAYER_ID(SESSION_USER), reference_id , quantity, code, 'f',(SELECT last_value FROM tic_seq));

	RETURN TRUE;
END 
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;






CREATE OR REPLACE FUNCTION convert_resource(current_resource_type character varying, amount bigint)
  RETURNS bigint AS
$BODY$
DECLARE
	amount_of_new_resource bigint;
	fuel_check bigint;
	money_check bigint;
BEGIN
	SET search_path to public;
	SELECT INTO fuel_check, money_check fuel_reserve, balance FROM player WHERE id=GET_PLAYER_ID(SESSION_USER);
	IF current_resource_type = 'FUEL' THEN
		IF amount >= 0 AND  amount <= fuel_check THEN
			--SELECT INTO amount_of_new_resource (fuel_reserve/balance*amount)::bigint FROM player WHERE id=0;
			amount_of_new_resource := amount;
			UPDATE player SET fuel_reserve=fuel_reserve-amount, balance=balance+amount_of_new_resource WHERE id=GET_PLAYER_ID(SESSION_USER);
			--UPDATE player SET balance=balance-amount, fuel_reserve=fuel_reserve+amount_of_new_resource WHERE id=0;
		ELSE
  			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''You do not have that much fuel to convert'';';
		END IF;
	ELSEIF current_resource_type = 'MONEY' THEN
		IF  amount >= 0 AND amount <= money_check THEN
			--SELECT INTO amount_of_new_resource (balance/fuel_reserve*amount)::bigint FROM player WHERE id=0;
			amount_of_new_resource := amount;
			UPDATE player SET balance=balance-amount, fuel_reserve=fuel_reserve+amount_of_new_resource WHERE id=GET_PLAYER_ID(SESSION_USER);
			--UPDATE player SET fuel_reserve=fuel_reserve-amount, balance=balance+amount_of_new_resource WHERE id=0;

		ELSE
  			EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''You do not have that much money to convert'';';
		END IF;
	END IF;

	RETURN amount_of_new_resource;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;







CREATE TABLE action
(
  name character(30) NOT NULL,
  string text NOT NULL,
  bitname bit(6) NOT NULL,
  CONSTRAINT action_pkey PRIMARY KEY (name),
  CONSTRAINT action_bitname_un UNIQUE (bitname)
);


COPY action (name, string, bitname) FROM stdin;
BUY_SHIP                      	(#%player_id_1%)%player_name_1% has purchased a new ship (#%ship_id_1%)%ship_name_1% and sent it to location %location%	000001
ATTACK                        	(#%player_id_1%)%player_name_1%'s ship (#%ship_id_1%)%ship_name_1% has attacked (#%player_id_2%)%player_name_2%'s ship (#%ship_id_2%)%ship_name_2% causing %descriptor_numeric% of damage	000000
CONQUER                       	(#%player_id_1%)%player_name_1% has conquered (#%referencing_id%)%planet_name% from (#%player_id_2%)%player_name_2%	000010
EXPLODE                       	(#%player_id_1%)%player_name_1%'s ship (#%ship_id_1%)%ship_name_1% has been destroyed	000011
MINE_FAIL                     	(#%player_id_1%)%player_name_1%'s ship (#%ship_id_1%)%ship_name_1% has failed to mine the planet (#%referencing_id%)%planet_name%	000110
MINE_SUCCESS                  	(#%player_id_1%)%player_name_1%'s ship (#%ship_id_1%)%ship_name_1% has successfully mined %descriptor_numeric% fuel from the planet (#%referencing_id%)%planet_name%	000111
REFUEL_SHIP                   	(#%player_id_1%)%player_name_1% has refueled the ship (#%ship_id_1%)%ship_name_1% +%descriptor_numeric%	001000
REPAIR                        	(#%player_id_1%)%player_name_1%'s ship (#%ship_id_1%)%ship_name_1% has repaired (#%ship_id_2%)%ship_name_2% by %descriptor_numeric%	001001
UPGRADE_SHIP                  	(#%player_id_1%)%player_name_1% has upgraded the %descriptor_string% on ship (#%ship_id_1%)%ship_name_1% +%descriptor_numeric%	010010
TIC                           	A new Tic has begun at %toc%	010101
FLEET                         	(#%player_id_1%)%player_name_1%'s new fleet (#%referencing_id%) has been upgraded	000101
FLEET_FAIL                    	(#%player_id_1%)%player_name_1%'s fleet #%referencing_id% encountered an issue during execution and was terminated. The error logged was: %descriptor_string%	010100
FLEET_SUCCESS                 	(#%player_id_1%)%player_name_1%'s fleet #%referencing_id% completed successfully. Execution took: %descriptor_string%	010011
\.






CREATE TABLE event
(
  id integer NOT NULL,
  action character(30) NOT NULL,
  player_id_1 integer,
  ship_id_1 integer,
  player_id_2 integer,
  ship_id_2 integer,
  referencing_id integer,
  descriptor_numeric numeric,
  descriptor_string character varying,
  location_x integer,
  location_y integer,
  public boolean DEFAULT false,
  tic integer NOT NULL,
  toc timestamp without time zone NOT NULL DEFAULT now(),
  location point,
  CONSTRAINT event_pkey PRIMARY KEY (id),
  CONSTRAINT event_action_fkey FOREIGN KEY (action)
      REFERENCES action (name) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT event_player_id_1_fkey FOREIGN KEY (player_id_1)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT event_player_id_2_fkey FOREIGN KEY (player_id_2)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT event_ship_id_1_fkey FOREIGN KEY (ship_id_1)
      REFERENCES ship (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT event_ship_id_2_fkey FOREIGN KEY (ship_id_2)
      REFERENCES ship (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION
);






CREATE SEQUENCE event_id_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;








CREATE OR REPLACE VIEW my_events AS 
 SELECT event.id, event.action, event.player_id_1, event.ship_id_1, 
    event.player_id_2, event.ship_id_2, event.referencing_id, 
    event.descriptor_numeric, event.descriptor_string, event.location, 
    event.public, event.tic, event.toc
   FROM event
  WHERE 
	( 
		get_player_id("session_user"()) = event.player_id_1 
		OR get_player_id("session_user"()) = event.player_id_2 
		OR event.public = true 
	)
	AND event.tic < (( SELECT tic_seq.last_value FROM tic_seq));









CREATE OR REPLACE FUNCTION read_event(read_event_id integer)
  RETURNS text AS
$BODY$
DECLARE
	full_text TEXT;
BEGIN
	-- Sometimes you just write some dirty code... 
	SELECT  
	replace(
	 replace(
	  replace(
	   replace(
	    replace(
	      replace(
	       replace(
	        replace(
	         replace(
	          replace(
	           replace(
	            replace(
	             replace(
	              replace(action.string,
	               '%toc', toc::TEXT),
	              '%player_id_1%', 	player_id_1::TEXT),
	             '%player_name_1%', COALESCE(GET_PLAYER_SYMBOL(player_id_1) || ' ','')||GET_PLAYER_USERNAME(player_id_1)),
	            '%player_id_2%', 	COALESCE(player_id_2::TEXT,'Unknown')),
	           '%player_name_2%', 	COALESCE(COALESCE(GET_PLAYER_SYMBOL(player_id_2) || ' ','')||GET_PLAYER_USERNAME(player_id_2),'Unknown')),
	          '%ship_id_1%', 	COALESCE(ship_id_1::TEXT,'Unknown')),
	         '%ship_id_2%', 	COALESCE(ship_id_2::TEXT,'Unknown')),
	        '%ship_name_1%', 	COALESCE(GET_SHIP_NAME(ship_id_1),'Unknown')),
	       '%ship_name_2%', 	COALESCE(GET_SHIP_NAME(ship_id_2),'Unknown')),
	      '%location%', 		COALESCE(location::TEXT,'Unknown')),
	    '%descriptor_numeric%', 	COALESCE(descriptor_numeric::TEXT,'Unknown')),
	   '%descriptor_string%', 	COALESCE(descriptor_string,'Unknown')),
	  '%referencing_id%', 		COALESCE(referencing_id::TEXT,'Unknown')),
	 '%planet_name%', 		COALESCE(GET_PLANET_NAME(referencing_id),'Unknown')
	) into full_text
	FROM my_events INNER JOIN action on my_events.action=action.name 
	WHERE my_events.id=read_event_id; 

        RETURN full_text;
END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;







CREATE OR REPLACE FUNCTION fleet_success_event(fleet integer, took interval)
  RETURNS boolean AS
$BODY$
BEGIN
	SET search_path to public;
	INSERT INTO event(action, player_id_1, public, tic, descriptor_string, referencing_id) 
		VALUES('FLEET_SUCCESS',GET_PLAYER_ID(SESSION_USER),'f',(SELECT last_value FROM tic_seq),took, fleet) ;
	RETURN 't';
END $BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;







CREATE OR REPLACE FUNCTION fleet_fail_event(fleet integer, error text)
  RETURNS boolean AS
$BODY$
BEGIN
	SET search_path to public;
	INSERT INTO event(action, player_id_1, public, tic, descriptor_string, referencing_id) 
		VALUES('FLEET_FAIL',GET_PLAYER_ID(SESSION_USER),'f',(SELECT last_value FROM tic_seq),error, fleet) ;
	RETURN 't';
END $BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;






CREATE OR REPLACE FUNCTION run_fleet_script(id integer)
  RETURNS boolean AS
$BODY$
DECLARE
    this_fleet_script_start timestamptz;
BEGIN
    this_fleet_script_start := current_timestamp;
    BEGIN
        EXECUTE 'SELECT FLEET_SCRIPT_' || id || '()';
    EXCEPTION
	WHEN OTHERS OR QUERY_CANCELED THEN 
		PERFORM fleet_fail_event(id, SQLERRM);
		RETURN false;
    END;
    
    PERFORM fleet_success_event(id, ( timeofday()::timestamp - this_fleet_script_start )::interval) ;
    RETURN true;
END $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;







CREATE TABLE planet
(
  id integer NOT NULL,
  name character varying,
  fuel integer NOT NULL DEFAULT (random() * (100000)::double precision),
  mine_limit integer NOT NULL DEFAULT (random() * (100)::double precision),
  difficulty integer NOT NULL DEFAULT (random() * (10)::double precision),
  location_x integer NOT NULL DEFAULT random(),
  location_y integer NOT NULL DEFAULT random(),
  conqueror_id integer,
  location point,
  CONSTRAINT planet_pkey PRIMARY KEY (id),
  CONSTRAINT planet_conqueror_id_fkey FOREIGN KEY (conqueror_id)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION
)
WITH (
  OIDS=FALSE
);






CREATE SEQUENCE planet_id_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;







CREATE OR REPLACE FUNCTION get_planet_name(planet_id integer)
  RETURNS character varying AS
$BODY$
DECLARE 
	found_planetname character varying;
BEGIN
	
	SELECT name INTO found_planetname FROM public.planet WHERE id=planet_id;
	RETURN found_planetname;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;








CREATE TABLE planet_miners
(
  planet_id integer NOT NULL,
  ship_id integer NOT NULL,
  CONSTRAINT planet_miners_pkey PRIMARY KEY (planet_id, ship_id),
  CONSTRAINT planet_miners_planet_id_fkey FOREIGN KEY (planet_id)
      REFERENCES planet (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT planet_miners_ship_id_fkey FOREIGN KEY (ship_id)
      REFERENCES ship (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION
)
WITH (
  OIDS=FALSE
);







CREATE OR REPLACE VIEW planets_in_range AS 
 SELECT s.id AS ship, sp.id AS planet, s.location AS ship_location, 
    sp.location AS planet_location, s.location <-> sp.location AS distance
   FROM ship s, planet sp
  WHERE 
	s.player_id = get_player_id("session_user"()) 
	AND NOT s.destroyed 
	AND circle(s.location, s.range::double precision) @> circle(sp.location, 1::double precision);







CREATE OR REPLACE VIEW planets AS 
 SELECT planet.id, planet.name, planet.mine_limit, planet.location_x, 
    planet.location_y, planet.conqueror_id, planet.location
   FROM planet;


CREATE OR REPLACE RULE planet_update AS
    ON UPDATE TO planets DO INSTEAD  UPDATE planet SET name = new.name
  WHERE planet.id <> 1 AND planet.id = new.id AND planet.conqueror_id = get_player_id("session_user"());







CREATE OR REPLACE FUNCTION update_planet()
  RETURNS trigger AS
$BODY$
BEGIN
	IF NEW.conqueror_id!=OLD.conqueror_id THEN
		INSERT INTO event(action, player_id_1, player_id_2, referencing_id, location, public, tic)
			VALUES('CONQUER',NEW.conqueror_id,OLD.conqueror_id, NEW.id , NEW.location, 't',(SELECT last_value FROM tic_seq));
	END IF;
	RETURN NEW;	
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;

CREATE TRIGGER update_planet
  AFTER UPDATE
  ON planet
  FOR EACH ROW
  EXECUTE PROCEDURE update_planet();







CREATE TABLE trophy
(
  id integer NOT NULL,
  name character varying,
  description text,
  picture_link text,
  script text,
  script_declarations text,
  creator integer NOT NULL,
  approved boolean DEFAULT false,
  round_started integer,
  weight smallint,
  run_order smallint,
  CONSTRAINT trophy_pkey PRIMARY KEY (id),
  CONSTRAINT trophy_creator_fkey FOREIGN KEY (creator)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION
)
WITH (
  OIDS=FALSE
);








CREATE SEQUENCE trophy_id_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9223372036854775807
  START 1
  CACHE 1;







CREATE OR REPLACE FUNCTION create_trophy()
  RETURNS trigger AS
$BODY$
BEGIN
     
	NEW.approved 	:= 'f';
	NEW.creator 	:= GET_PLAYER_ID(SESSION_USER);
	NEW.round_started := 0;

       RETURN NEW;
END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;



CREATE TRIGGER create_trophy
  BEFORE INSERT
  ON trophy
  FOR EACH ROW
  EXECUTE PROCEDURE create_trophy();






CREATE TYPE trophy_winner AS (round integer, trophy_id integer, player_id integer);









CREATE OR REPLACE FUNCTION trophy_script_update()
  RETURNS trigger AS
$BODY$
DECLARE
       current_round integer;
	secret character varying;

	player_id integer;
BEGIN

	player_id := GET_PLAYER_ID(SESSION_USER);

	IF  SESSION_USER = 'schemaverse' THEN
	       IF NEW.approved='t' AND OLD.approved='f' THEN
			IF NEW.round_started=0 THEN
				SELECT last_value INTO NEW.round_started FROM round_seq;
			END IF;

		        secret := 'trophy_script_' || (RANDOM()*1000000)::integer;
       		 EXECUTE 'CREATE OR REPLACE FUNCTION TROPHY_SCRIPT_'|| NEW.id ||'(_round_id integer) RETURNS SETOF trophy_winner AS $'||secret||'$
		        DECLARE
				this_trophy_id integer;
				this_round integer; -- Deprecated, use _round_id in your script instead
				 winner trophy_winner%rowtype;
       		         ' || NEW.script_declarations || '
		        BEGIN
       		         this_trophy_id := '|| NEW.id||';
       		         SELECT last_value INTO this_round FROM round_seq; 
	       	         ' || NEW.script || '
			 RETURN;
	       	 END $'||secret||'$ LANGUAGE plpgsql;'::TEXT;

		 EXECUTE 'REVOKE ALL ON FUNCTION TROPHY_SCRIPT_'|| NEW.id ||'(integer) FROM PUBLIC'::TEXT;
       		 EXECUTE 'REVOKE ALL ON FUNCTION TROPHY_SCRIPT_'|| NEW.id ||'(integer) FROM players'::TEXT;
		 EXECUTE 'GRANT EXECUTE ON FUNCTION TROPHY_SCRIPT_'|| NEW.id ||'(integer) TO schemaverse'::TEXT;
		END IF;
	ELSEIF NOT player_id = OLD.creator THEN
		RETURN OLD;
	ELSE 
		IF NOT OLD.approved = NEW.approved THEN
			NEW.approved='f';
		END IF;

		IF NOT ((NEW.script = OLD.script) AND (NEW.script_declarations = OLD.script_declarations)) THEN
			NEW.approved='f';	         
	       END IF;
	END IF;

       RETURN NEW;
END $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;


CREATE TRIGGER trophy_script_update
  BEFORE UPDATE
  ON trophy
  FOR EACH ROW
  EXECUTE PROCEDURE trophy_script_update();
ALTER TABLE trophy DISABLE TRIGGER trophy_script_update;








CREATE TABLE player_trophy
(
  round integer NOT NULL,
  trophy_id integer NOT NULL,
  player_id integer NOT NULL,
  CONSTRAINT player_trophy_pkey PRIMARY KEY (round, trophy_id, player_id),
  CONSTRAINT player_trophy_player_id_fkey FOREIGN KEY (player_id)
      REFERENCES player (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT player_trophy_trophy_id_fkey FOREIGN KEY (trophy_id)
      REFERENCES trophy (id) MATCH SIMPLE
      ON UPDATE NO ACTION ON DELETE NO ACTION
)
WITH (
  OIDS=FALSE
);








CREATE OR REPLACE VIEW trophy_case AS 
 SELECT player_trophy.player_id, 
    get_player_username(player_trophy.player_id) AS username, 
    trophy.name AS trophy, count(player_trophy.trophy_id) AS times_awarded, 
    ( SELECT t.round
           FROM player_trophy t
          WHERE t.trophy_id = player_trophy.trophy_id AND t.player_id = player_trophy.player_id
          ORDER BY t.round DESC
         LIMIT 1) AS last_round_won
   FROM trophy, player_trophy
  WHERE trophy.id = player_trophy.trophy_id
  GROUP BY player_trophy.trophy_id, trophy.name, player_trophy.player_id;






CREATE OR REPLACE FUNCTION id_dealer()
  RETURNS trigger AS
$BODY$
BEGIN

	IF (TG_OP = 'INSERT') THEN 
		NEW.id = nextval(TG_TABLE_NAME || '_id_seq');
	ELSEIF (TG_OP = 'UPDATE') THEN
		NEW.id = OLD.id;
	END IF;
RETURN NEW;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE TRIGGER PLAYER_ID_DEALER BEFORE INSERT OR UPDATE ON player
  FOR EACH ROW EXECUTE PROCEDURE ID_DEALER(); 

CREATE TRIGGER SHIP_ID_DEALER BEFORE INSERT OR UPDATE ON ship
  FOR EACH ROW EXECUTE PROCEDURE ID_DEALER(); 

CREATE TRIGGER FLEET_ID_DEALER BEFORE INSERT OR UPDATE ON fleet
  FOR EACH ROW EXECUTE PROCEDURE ID_DEALER(); 

CREATE TRIGGER EVENT_ID_DEALER BEFORE INSERT OR UPDATE ON event
  FOR EACH ROW EXECUTE PROCEDURE ID_DEALER(); 

CREATE TRIGGER TROPHY_ID_DEALER BEFORE INSERT OR UPDATE ON trophy
  FOR EACH ROW EXECUTE PROCEDURE ID_DEALER();









CREATE OR REPLACE FUNCTION general_permission_check()
  RETURNS trigger AS
$BODY$
DECLARE
        real_player_id integer;
        checked_player_id integer;
BEGIN
        IF SESSION_USER = 'schemaverse' THEN
                RETURN NEW;
        ELSEIF CURRENT_USER = 'schemaverse' THEN
                SELECT id INTO real_player_id FROM player WHERE username=SESSION_USER;

                IF TG_TABLE_NAME IN ('ship','fleet','trade_item') THEN
                        IF (TG_OP = 'DELETE') THEN
				RETURN OLD;
			ELSE 
			 	RETURN NEW;
			END IF;
                ELSEIF TG_TABLE_NAME = 'trade' THEN
                        IF TG_OP = 'UPDATE' THEN
                                IF (OLD.player_id_1 != NEW.player_id_1) OR (OLD.player_id_2 != NEW.player_id_2) THEN
                                        RETURN NULL;
                                END IF;
                                IF NEW.confirmation_1 != OLD.confirmation_1 AND NEW.player_id_1 != real_player_id THEN
                                        RETURN NULL;
                                END IF;
                                IF NEW.confirmation_2 != OLD.confirmation_2 AND NEW.player_id_2 != real_player_id THEN
                                        RETURN NULL;
                                END IF;
                        ELSEIF TG_OP = 'DELETE' THEN
	                         IF real_player_id in (OLD.player_id_1, OLD.player_id_2) THEN
					RETURN OLD;
				ELSE 
					RETURN NULL;
				END IF;
			END IF;
			
                         IF real_player_id in (NEW.player_id_1, NEW.player_id_2) THEN
                                RETURN NEW;
                        END IF;
                ELSEIF TG_TABLE_NAME in ('ship_control') THEN
                        IF TG_OP = 'UPDATE' THEN
                                IF OLD.ship_id != NEW.ship_id THEN
                                        RETURN NULL;
				  END IF;
                        END IF;
                        SELECT player_id INTO checked_player_id FROM ship WHERE id=NEW.ship_id;
                        IF real_player_id = checked_player_id THEN
                                RETURN NEW;
                        END IF;
                END IF;

        ELSE

                SELECT id INTO real_player_id FROM player WHERE username=SESSION_USER;

                IF TG_TABLE_NAME IN ('ship','fleet','trade_item') THEN
                        IF TG_OP = 'UPDATE' THEN
                                IF OLD.player_id != NEW.player_id THEN
                                        RETURN NULL;
                                END IF;
                        END IF;
                        NEW.player_id = real_player_id;
                        RETURN NEW;

                ELSEIF TG_TABLE_NAME = 'trade' THEN
                        IF TG_OP = 'UPDATE' THEN
                                IF (OLD.player_id_1 != NEW.player_id_1) OR (OLD.player_id_2 != NEW.player_id_2) THEN
                                        RETURN NULL;
                                END IF;
                                IF NEW.confirmation_1 != OLD.confirmation_1 AND NEW.player_id_1 != real_player_id THEN
                                        RETURN NULL;
                                END IF;
                                IF NEW.confirmation_2 != OLD.confirmation_2 AND NEW.player_id_2 != real_player_id THEN
                                        RETURN NULL;
                                END IF;
                        END IF;
                         IF real_player_id in (NEW.player_id_1, NEW.player_id_2) THEN
                                RETURN NEW;
                        END IF;
                ELSEIF TG_TABLE_NAME in ('ship_control') THEN
                        IF TG_OP = 'UPDATE' THEN
                                IF OLD.ship_id != NEW.ship_id THEN
                                        RETURN NULL;
				  END IF;
                        END IF;
                        SELECT player_id INTO checked_player_id FROM ship WHERE id=NEW.ship_id;
                        IF real_player_id = checked_player_id THEN
                                RETURN NEW;
                        END IF;
                END IF;
        END IF;
        RETURN NULL;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE TRIGGER A_SHIP_PERMISSION_CHECK BEFORE INSERT OR UPDATE ON ship
  FOR EACH ROW EXECUTE PROCEDURE GENERAL_PERMISSION_CHECK(); 

CREATE TRIGGER A_SHIP_CONTROL_PERMISSION_CHECK BEFORE INSERT OR UPDATE OR DELETE ON ship_control
  FOR EACH ROW EXECUTE PROCEDURE GENERAL_PERMISSION_CHECK(); 

CREATE TRIGGER A_FLEET_PERMISSION_CHECK BEFORE INSERT OR UPDATE OR DELETE ON fleet
  FOR EACH ROW EXECUTE PROCEDURE GENERAL_PERMISSION_CHECK(); 








CREATE OR REPLACE FUNCTION action_permission_check(ship_id integer)
  RETURNS boolean AS
$BODY$
DECLARE 
	ships_player_id integer;
	lat integer;
	exploded boolean;
	ch integer;
BEGIN
	SET search_path to public;
	SELECT player_id, last_action_tic, destroyed, current_health into ships_player_id, lat, exploded, ch FROM ship WHERE id=ship_id ;
	IF (
		lat != (SELECT last_value FROM tic_seq)
		AND
		exploded = 'f'
		AND 
		ch > 0 
	) AND (
		ships_player_id = GET_PLAYER_ID(SESSION_USER) 
			OR (ships_player_id > 0 AND (SESSION_USER = 'schemaverse' OR CURRENT_USER = 'schemaverse'))  
			)
			THEN
		
		RETURN 't';
	ELSE 
		RETURN 'f';
	END IF;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;







CREATE OR REPLACE FUNCTION in_range_ship(ship_1 integer, ship_2 integer)
  RETURNS boolean AS
$BODY$
	SET search_path to public;
	select exists (select 1 from ship enemies, ship players
	       	       where 
		       	  players.id = $1 and enemies.id = $2 and
                          not enemies.destroyed AND NOT players.destroyed and
                          CIRCLE(players.location, players.range) @> CIRCLE(enemies.location, 1));
$BODY$
  LANGUAGE sql VOLATILE SECURITY DEFINER
  COST 100;








CREATE OR REPLACE FUNCTION in_range_planet(ship_id integer, planet_id integer)
  RETURNS boolean AS
$BODY$
	SET search_path to public;
	select exists (select 1 from planet p, ship s
	       	       where 
		       	  s.id = $1 and p.id = $2 and
                          not s.destroyed and
                          CIRCLE(s.location, s.range) @> CIRCLE(p.location, 1));
$BODY$
  LANGUAGE sql VOLATILE SECURITY DEFINER
  COST 100;









CREATE OR REPLACE FUNCTION attack(attacker integer, enemy_ship integer)
  RETURNS integer AS
$BODY$
DECLARE
	damage integer;
	attack_rate integer;
	defense_rate integer;
	attacker_name character varying;
	attacker_player_id integer;
	enemy_name character varying;
	enemy_player_id integer;
	defense_efficiency numeric;
	loc point;
BEGIN
	SET search_path to public;
	damage = 0;
	--check range
	IF ACTION_PERMISSION_CHECK(attacker) AND (IN_RANGE_SHIP(attacker, enemy_ship)) THEN

		defense_efficiency := GET_NUMERIC_VARIABLE('DEFENSE_EFFICIENCY') / 100::numeric;

		--FINE, I won't divide by zero
		SELECT attack + 1, player_id, name, location INTO attack_rate, attacker_player_id, attacker_name, loc FROM ship WHERE id=attacker;
		SELECT defense + 1, player_id, name INTO defense_rate, enemy_player_id, enemy_name FROM ship WHERE id=enemy_ship;

		damage = (attack_rate * (defense_efficiency/defense_rate+defense_efficiency))::integer;		
		UPDATE ship SET future_health=future_health-damage WHERE id=enemy_ship;
		UPDATE ship SET last_action_tic=(SELECT last_value FROM tic_seq) WHERE id=attacker;

		INSERT INTO event(action, player_id_1,ship_id_1, player_id_2, ship_id_2, descriptor_numeric, location,public, tic)
			VALUES('ATTACK',attacker_player_id, attacker, enemy_player_id, enemy_ship , damage, loc, 't',(SELECT last_value FROM tic_seq));
	ELSE 
		 EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Attack from ' || attacker || ' to '|| enemy_ship ||' failed'';';
	END IF;	

	RETURN damage;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;









CREATE OR REPLACE FUNCTION repair(repair_ship integer, repaired_ship integer)
  RETURNS integer AS
$BODY$
DECLARE
	repair_rate integer;
	repair_ship_name character varying;
	repair_ship_player_id integer;
	repaired_ship_name character varying;
	loc point;
BEGIN
	SET search_path to public;

	repair_rate = 0;


	--check range
	IF ACTION_PERMISSION_CHECK(repair_ship) AND (IN_RANGE_SHIP(repair_ship, repaired_ship)) THEN

		SELECT engineering, player_id, name, location INTO repair_rate, repair_ship_player_id, repair_ship_name, loc FROM ship WHERE id=repair_ship;
		SELECT name INTO repaired_ship_name FROM ship WHERE id=repaired_ship;
		UPDATE ship SET future_health = future_health + repair_rate WHERE id=repaired_ship;
		UPDATE ship SET last_action_tic=(SELECT last_value FROM tic_seq) WHERE id=repair_ship;

		INSERT INTO event(action, player_id_1,ship_id_1, ship_id_2, descriptor_numeric, location, public, tic)
			VALUES('REPAIR',repair_ship_player_id, repair_ship,  repaired_ship , repair_rate,loc,'t',(SELECT last_value FROM tic_seq));

	ELSE 
		 EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Repair from ' || repair_ship || ' to '|| repaired_ship ||' failed'';';
	END IF;	

	RETURN repair_rate;
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;










CREATE OR REPLACE FUNCTION mine(ship_id integer, planet_id integer)
  RETURNS boolean AS
$BODY$
BEGIN
	SET search_path to public;
	IF ACTION_PERMISSION_CHECK(ship_id) AND (IN_RANGE_PLANET(ship_id, planet_id)) THEN
		INSERT INTO planet_miners VALUES(planet_id, ship_id);
		UPDATE ship SET last_action_tic=(SELECT last_value FROM tic_seq) WHERE id=ship_id;
		RETURN 't';
	ELSE
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Mining ' || planet_id || ' with ship '|| ship_id ||' failed'';';
		RETURN 'f';
	END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;








CREATE OR REPLACE FUNCTION perform_mining()
  RETURNS integer AS
$BODY$
DECLARE
	miners RECORD;
	current_planet_id integer;
	current_planet_limit integer;
	current_planet_difficulty integer;
	current_planet_fuel integer;
	limit_counter integer;
	mined_player_fuel integer;
	mine_base_fuel integer;

	new_fuel_reserve bigint;
	current_tic integer;
BEGIN
	SET search_path to public;
	current_planet_id = 0; 
	mine_base_fuel = GET_NUMERIC_VARIABLE('MINE_BASE_FUEL');
	
	CREATE TEMPORARY TABLE temp_mined_player (
		player_id integer,
		planet_id integer,
		fuel_mined bigint
	);

	CREATE TEMPORARY TABLE temp_event (
		action CHARACTER(30), 
		player_id_1 integer,
		ship_id_1 integer, 
		referencing_id integer, 
		descriptor_numeric integer,
		location POINT, 
		public boolean
	);

	FOR miners IN 
		SELECT 
			planet_miners.planet_id as planet_id, 
			planet_miners.ship_id as ship_id, 
			ship.player_id as player_id, 
			ship.prospecting as prospecting,
			ship.location as location
			FROM 
				planet_miners, ship
			WHERE
				planet_miners.ship_id=ship.id
			ORDER BY planet_miners.planet_id, (ship.prospecting * RANDOM()) LOOP 

		IF current_planet_id != miners.planet_id THEN
			limit_counter := 0;
			current_planet_id := miners.planet_id;
			SELECT INTO current_planet_fuel, current_planet_difficulty, current_planet_limit fuel, difficulty, mine_limit FROM planet WHERE id=current_planet_id;
		END IF;

		--Added current_planet_fuel check here to fix negative fuel_reserve
		IF limit_counter < current_planet_limit AND current_planet_fuel > 0 THEN
			mined_player_fuel := (mine_base_fuel * RANDOM() * miners.prospecting * current_planet_difficulty)::integer;
			IF mined_player_fuel > current_planet_fuel THEN 
				mined_player_fuel = current_planet_fuel;
			END IF;

			IF mined_player_fuel <= 0 THEN
				INSERT INTO temp_event(action, player_id_1,ship_id_1, referencing_id, location, public)
					VALUES('MINE_FAIL',miners.player_id, miners.ship_id, miners.planet_id, miners.location,'f');		
			ELSE 


				current_planet_fuel := current_planet_fuel - mined_player_fuel;

				UPDATE temp_mined_player SET fuel_mined=fuel_mined + mined_player_fuel WHERE player_id=miners.player_id and planet_id=current_planet_id;
				IF NOT FOUND THEN
					INSERT INTO temp_mined_player VALUES (miners.player_id, current_planet_id, mined_player_fuel);
				END IF;

				INSERT INTO temp_event(action, player_id_1,ship_id_1, referencing_id, descriptor_numeric, location, public)
					VALUES('MINE_SUCCESS',miners.player_id, miners.ship_id, miners.planet_id , mined_player_fuel,miners.location,'f');
			END IF;
			limit_counter = limit_counter + 1;
		ELSE
			--INSERT INTO event(action, player_id_1,ship_id_1, referencing_id, location, public, tic)
			--	VALUES('MINE_FAIL',miners.player_id, miners.ship_id, miners.planet_id, miners.location,'f',(SELECT last_value FROM tic_seq));
		END IF;		
	END LOOP;

	DELETE FROM planet_miners;

	WITH tmp AS (SELECT player_id, SUM(fuel_mined) as fuel_mined FROM temp_mined_player GROUP BY player_id)
		UPDATE player SET fuel_reserve = fuel_reserve + tmp.fuel_mined FROM tmp WHERE player.id = tmp.player_id;

	WITH tmp AS (SELECT planet_id, SUM(fuel_mined) as fuel_mined FROM temp_mined_player GROUP BY planet_id)
		UPDATE planet SET fuel = GREATEST(fuel - tmp.fuel_mined,0) FROM tmp WHERE planet.id = tmp.planet_id;

	INSERT INTO event(action, player_id_1,ship_id_1, referencing_id, descriptor_numeric, location, public, tic) SELECT temp_event.*, (SELECT last_value FROM tic_seq) FROM temp_event;

	current_planet_id = 0; 

	FOR miners IN SELECT count(event.player_id_1) as mined, event.referencing_id as planet_id, event.player_id_1 as player_id, 
			CASE WHEN (select conqueror_id from planet where id=event.referencing_id)=event.player_id_1 THEN 2 ELSE 1 END as current_conqueror
			FROM temp_event event
			WHERE event.action='MINE_SUCCESS'
			GROUP BY event.referencing_id, event.player_id_1
			ORDER BY planet_id, mined DESC, current_conqueror DESC LOOP

		IF current_planet_id != miners.planet_id THEN
			current_planet_id := miners.planet_id;
			IF miners.current_conqueror=1 THEN
				UPDATE 	planet 	SET conqueror_id=miners.player_id WHERE planet.id=miners.planet_id;
			END IF;
		END IF;
	END LOOP;

	RETURN 1;
END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;








CREATE OR REPLACE FUNCTION ship_course_control(moving_ship_id integer, new_speed integer, new_direction integer, new_destination point)
  RETURNS boolean AS
$BODY$
DECLARE
	max_speed integer;
	ship_player_id integer;
BEGIN
	SET search_path to public;
	-- Bunch of cases where this function fails, quietly
	IF moving_ship_id IS NULL then
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Attempt to course control on NULL ship'';';
		RETURN 'f';
	END IF;
	if new_speed IS NULL then
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Attempt to course control NULL speed'';';
		RETURN 'f';
	END IF;
	if (new_direction IS NOT NULL AND new_destination IS NOT NULL) then
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Attempt to course control with both direction and destination'';';
		RETURN 'f';
	END IF;
	IF (new_direction IS NULL AND new_destination IS NULL) THEN
		EXECUTE 'NOTIFY ' || get_player_error_channel() ||', ''Attempt to course control with neither direction nor destination'';';
		RETURN 'f';
	END IF;

	SELECT INTO max_speed, ship_player_id  ship.max_speed, player_id from ship WHERE id=moving_ship_id;
	IF ship_player_id IS NULL OR ship_player_id <> GET_PLAYER_ID(SESSION_USER) THEN
		RETURN 'f';
	END IF;
	IF new_speed > max_speed THEN
		new_speed := max_speed;
	END IF;
	UPDATE ship_control SET
	  target_speed = new_speed,
	  target_direction = new_direction,
	  destination = new_destination,
	  destination_x = new_destination[0],
	  destination_y = new_destination[1]
	  WHERE ship_id = moving_ship_id;

	RETURN 't';
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;



CREATE OR REPLACE FUNCTION ship_course_control(moving_ship_id integer, new_speed integer, new_direction integer, new_destination_x integer, new_destination_y integer)
  RETURNS boolean AS
$BODY$
DECLARE
	max_speed integer;
	ship_player_id integer;
BEGIN
	SET search_path to public;
	
	RETURN SHIP_COURSE_CONTROL(moving_ship_id, new_speed, new_direction, POINT(new_destination_x, new_destination_y));
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;


CREATE OR REPLACE FUNCTION scc(moving_ship_id integer, new_speed integer, new_direction integer, new_destination_x integer, new_destination_y integer)
  RETURNS boolean AS
$BODY$
DECLARE
BEGIN
	SET search_path to public;
	RETURN ship_course_control(moving_ship_id , new_speed , new_direction , new_destination_x , new_destination_y );
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;









CREATE OR REPLACE FUNCTION move_ships()
  RETURNS boolean AS
$BODY$
DECLARE
	
	ship_control_ record;
	velocity point;
	new_velocity point;
	vector point;
	delta_v numeric;
	acceleration_angle numeric;
	distance bigint;
	current_tic integer;
BEGIN
	SET search_path to public;
        IF NOT SESSION_USER = 'schemaverse' THEN
                RETURN 'f';
        END IF;

	SELECT last_value INTO current_tic FROM tic_seq;
	
	FOR ship_control_ IN SELECT SC.*, S.* FROM ship_control SC
          INNER JOIN ship S ON S.id = SC.ship_id
	  WHERE (SC.target_speed <> SC.speed
	  OR SC.target_direction <> SC.direction
	  OR SC.speed <> 0) AND SC.destination<->S.location > 1 
          AND S.destroyed='f' AND S.last_move_tic <> current_tic LOOP

	
	  -- If ship is being controlled by a set destination, adjust angle and speed appropriately
	  IF ship_control_.destination IS NOT NULL THEN
            distance :=  (ship_control_.destination <-> ship_control_.location)::bigint;
	    IF distance < ship_control_.target_speed OR ship_control_.target_speed IS NULL THEN
	      ship_control_.target_speed = distance::int;
            END IF;
	    vector := ship_control_.destination - ship_control_.location;
	    ship_control_.target_direction := DEGREES(ATAN2(vector[1], vector[0]))::int;
	    IF ship_control_.target_direction < 0 THEN
	      ship_control_.target_direction := ship_control_.target_direction + 360;
	    END IF;
	  END IF;

	  velocity := point(COS(RADIANS(ship_control_.direction)) * ship_control_.speed,
	                    SIN(RADIANS(ship_control_.direction)) * ship_control_.speed);

	  new_velocity := point(COS(RADIANS(coalesce(ship_control_.target_direction,0))) * ship_control_.target_speed,
	  	       	        SIN(RADIANS(coalesce(ship_control_.target_direction,0))) * ship_control_.target_speed);

	  vector := new_velocity - velocity;
	  delta_v := velocity <-> new_velocity;
	  acceleration_angle := ATAN2(vector[1], vector[0]);

          IF ship_control_.current_fuel < delta_v THEN
	    delta_v := ship_control_.current_fuel;
	  END IF;

	  new_velocity := velocity + point(COS(acceleration_angle)*delta_v, SIN(acceleration_angle)*delta_v);
	  ship_control_.direction = DEGREES(ATAN2(new_velocity[1], new_velocity[0]))::int;
	  IF ship_control_.direction < 0 THEN
	    ship_control_.direction := ship_control_.direction + 360;
	  END IF;
	  ship_control_.speed =  (new_velocity <-> point(0,0))::integer;
	  ship_control_.current_fuel := ship_control_.current_fuel - delta_v::int;

          -- Move the ship!
         UPDATE ship S SET
		last_move_tic = current_tic,
		current_fuel = ship_control_.current_fuel,
		location = ship_control_.location + point(COS(RADIANS(ship_control_.direction)) * ship_control_.speed,
		                                 SIN(RADIANS(ship_control_.direction)) * ship_control_.speed)
                WHERE S.id = ship_control_.id;

          UPDATE ship S SET
		location_x = location[0],
		location_y = location[1]
                WHERE S.id = ship_control_.id;
          
	  UPDATE ship_control SC SET 
		speed = ship_control_.speed,
		direction = ship_control_.direction
                WHERE SC.ship_id = ship_control_.id;
	
	END LOOP;

	RETURN 't';
END
$BODY$
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  COST 100;







CREATE OR REPLACE VIEW current_stats AS 
 SELECT ( SELECT tic_seq.last_value
           FROM tic_seq) AS current_tic, 
    count(player.id) AS total_players, 
    ( SELECT count(online_players.id) AS count
           FROM online_players) AS online_players, 
    ( SELECT count(ship.id) AS count
           FROM ship) AS total_ships, 
    ceil(avg(( SELECT count(ship.id) AS count
           FROM ship
          WHERE ship.player_id = player.id
          GROUP BY ship.player_id))) AS avg_ships, 
    ( SELECT sum(player.fuel_reserve) AS sum
           FROM player
          WHERE player.id <> 0) AS total_fuel_reserves, 
    ceil(( SELECT avg(player.fuel_reserve) AS avg
           FROM player
          WHERE player.id <> 0)) AS avg_fuel_reserve, 
    ( SELECT sum(player.balance) AS sum
           FROM player
          WHERE player.id <> 0) AS total_currency, 
    ceil(( SELECT avg(player.balance) AS avg
           FROM player
          WHERE player.id <> 0)) AS avg_balance, 
    ( SELECT round_seq.last_value
           FROM round_seq) AS current_round
   FROM player;







CREATE OR REPLACE VIEW current_player_stats AS 
 SELECT player.id AS player_id, player.username, 
    COALESCE(against_player.damage_taken, 0::numeric) AS damage_taken, 
    COALESCE(for_player.damage_done, 0::numeric) AS damage_done, 
    COALESCE(for_player.planets_conquered, 0::bigint) AS planets_conquered, 
    COALESCE(against_player.planets_lost, 0::bigint) AS planets_lost, 
    COALESCE(for_player.ships_built, 0::bigint) AS ships_built, 
    COALESCE(for_player.ships_lost, 0::bigint) AS ships_lost, 
    COALESCE(for_player.ship_upgrades, 0::numeric) AS ship_upgrades, 
    COALESCE((( SELECT sum(r.location <-> r2.location)::bigint AS sum
           FROM ship_flight_recorder r, ship_flight_recorder r2, ship s
          WHERE s.player_id = player.id AND r.ship_id = s.id AND r2.ship_id = r.ship_id AND r2.tic = (r.tic + 1)))::numeric, 0::numeric) AS distance_travelled, 
    COALESCE(for_player.fuel_mined, 0::numeric) AS fuel_mined
   FROM player
   LEFT JOIN ( SELECT sum(
                CASE
                    WHEN event.action = 'ATTACK'::bpchar THEN event.descriptor_numeric
                    ELSE NULL::numeric
                END) AS damage_done, 
            count(
                CASE
                    WHEN event.action = 'CONQUER'::bpchar THEN COALESCE(event.descriptor_numeric, 0::numeric)
                    ELSE NULL::numeric
                END) AS planets_conquered, 
            count(
                CASE
                    WHEN event.action = 'BUY_SHIP'::bpchar THEN COALESCE(event.descriptor_numeric, 0::numeric)
                    ELSE NULL::numeric
                END) AS ships_built, 
            count(
                CASE
                    WHEN event.action = 'EXPLODE'::bpchar THEN COALESCE(event.descriptor_numeric, 0::numeric)
                    ELSE NULL::numeric
                END) AS ships_lost, 
            sum(
                CASE
                    WHEN event.action = 'UPGRADE_SHIP'::bpchar THEN event.descriptor_numeric
                    ELSE NULL::numeric
                END) AS ship_upgrades, 
            sum(
                CASE
                    WHEN event.action = 'MINE_SUCCESS'::bpchar THEN event.descriptor_numeric
                    ELSE NULL::numeric
                END) AS fuel_mined, 
            event.player_id_1
           FROM event event
          WHERE event.action = ANY (ARRAY['ATTACK'::bpchar, 'CONQUER'::bpchar, 'BUY_SHIP'::bpchar, 'EXPLODE'::bpchar, 'UPGRADE_SHIP'::bpchar, 'MINE_SUCCESS'::bpchar])
          GROUP BY event.player_id_1) for_player ON for_player.player_id_1 = player.id
   LEFT JOIN ( SELECT sum(
           CASE
               WHEN event.action = 'ATTACK'::bpchar THEN event.descriptor_numeric
               ELSE NULL::numeric
           END) AS damage_taken, 
       count(
           CASE
               WHEN event.action = 'CONQUER'::bpchar THEN COALESCE(event.descriptor_numeric, 0::numeric)
               ELSE NULL::numeric
           END) AS planets_lost, 
       event.player_id_2
      FROM event event
     WHERE event.action = ANY (ARRAY['ATTACK'::bpchar, 'CONQUER'::bpchar])
     GROUP BY event.player_id_2) against_player ON against_player.player_id_2 = player.id
  WHERE player.id <> 0;







CREATE TABLE player_round_stats
(
  player_id integer NOT NULL,
  round_id integer NOT NULL,
  damage_taken bigint NOT NULL DEFAULT 0,
  damage_done bigint NOT NULL DEFAULT 0,
  planets_conquered smallint NOT NULL DEFAULT 0,
  planets_lost smallint NOT NULL DEFAULT 0,
  ships_built smallint NOT NULL DEFAULT 0,
  ships_lost smallint NOT NULL DEFAULT 0,
  ship_upgrades integer NOT NULL DEFAULT 0,
  fuel_mined bigint NOT NULL DEFAULT 0,
  trophy_score smallint NOT NULL DEFAULT 0,
  last_updated timestamp without time zone NOT NULL DEFAULT now(),
  distance_travelled bigint NOT NULL DEFAULT 0,
  CONSTRAINT pk_player_round_stats PRIMARY KEY (player_id, round_id)
)
WITH (
  OIDS=FALSE
);






CREATE TABLE player_overall_stats
(
  player_id integer NOT NULL,
  damage_taken bigint,
  damage_done bigint,
  planets_conquered integer,
  planets_lost integer,
  ships_built integer,
  ships_lost integer,
  ship_upgrades bigint,
  distance_travelled bigint,
  fuel_mined bigint,
  trophy_score integer,
  CONSTRAINT pk_player_overall_stats PRIMARY KEY (player_id)
)
WITH (
  OIDS=FALSE
);







CREATE OR REPLACE VIEW current_round_stats AS 
 SELECT round.round_id, 
    COALESCE(avg(
        CASE
            WHEN against_player.action = 'ATTACK'::bpchar THEN COALESCE(against_player.sum, 0::numeric)
            ELSE NULL::numeric
        END), 0::numeric)::integer AS avg_damage_taken, 
    COALESCE(avg(
        CASE
            WHEN for_player.action = 'ATTACK'::bpchar THEN COALESCE(for_player.sum, 0::numeric)
            ELSE NULL::numeric
        END), 0::numeric)::integer AS avg_damage_done, 
    COALESCE(avg(
        CASE
            WHEN for_player.action = 'CONQUER'::bpchar THEN COALESCE(for_player.count, 0::bigint)
            ELSE NULL::bigint
        END), 0::numeric)::integer AS avg_planets_conquered, 
    COALESCE(avg(
        CASE
            WHEN against_player.action = 'CONQUER'::bpchar THEN COALESCE(against_player.count, 0::bigint)
            ELSE NULL::bigint
        END), 0::numeric)::integer AS avg_planets_lost, 
    COALESCE(avg(
        CASE
            WHEN for_player.action = 'BUY_SHIP'::bpchar THEN COALESCE(for_player.count, 0::bigint)
            ELSE NULL::bigint
        END), 0::numeric)::integer AS avg_ships_built, 
    COALESCE(avg(
        CASE
            WHEN for_player.action = 'EXPLODE'::bpchar THEN COALESCE(for_player.count, 0::bigint)
            ELSE NULL::bigint
        END), 0::numeric)::integer AS avg_ships_lost, 
    COALESCE(avg(
        CASE
            WHEN for_player.action = 'UPGRADE_SHIP'::bpchar THEN COALESCE(for_player.sum, 0::numeric)
            ELSE NULL::numeric
        END), 0::numeric)::bigint AS avg_ship_upgrades, 
    COALESCE(avg(
        CASE
            WHEN for_player.action = 'MINE_SUCCESS'::bpchar THEN COALESCE(for_player.sum, 0::numeric)
            ELSE NULL::numeric
        END), 0::numeric)::bigint AS avg_fuel_mined, 
    ( SELECT avg(prs.distance_travelled) AS avg
           FROM player_round_stats prs
          WHERE prs.round_id = round.round_id) AS avg_distance_travelled
   FROM ( SELECT round_seq.last_value AS round_id
           FROM round_seq) round
   LEFT JOIN ( SELECT ( SELECT round_seq.last_value AS round_id
                   FROM round_seq) AS round_id, 
            event.action, 
                CASE
                    WHEN event.action = ANY (ARRAY['ATTACK'::bpchar, 'UPGRADE_SHIP'::bpchar, 'MINE_SUCCESS'::bpchar]) THEN sum(COALESCE(event.descriptor_numeric, 0::numeric))
                    ELSE NULL::numeric
                END AS sum, 
                CASE
                    WHEN event.action = ANY (ARRAY['BUY_SHIP'::bpchar, 'EXPLODE'::bpchar, 'CONQUER'::bpchar]) THEN count(*)
                    ELSE NULL::bigint
                END AS count
           FROM event event
          WHERE event.action = ANY (ARRAY['ATTACK'::bpchar, 'CONQUER'::bpchar, 'BUY_SHIP'::bpchar, 'EXPLODE'::bpchar, 'UPGRADE_SHIP'::bpchar, 'MINE_SUCCESS'::bpchar])
          GROUP BY event.player_id_1, event.action) for_player ON for_player.round_id = round.round_id
   LEFT JOIN ( SELECT ( SELECT round_seq.last_value AS round_id
              FROM round_seq) AS round_id, 
       event.action, 
           CASE
               WHEN event.action = 'ATTACK'::bpchar THEN sum(COALESCE(event.descriptor_numeric, 0::numeric))
               ELSE NULL::numeric
           END AS sum, 
           CASE
               WHEN event.action = 'CONQUER'::bpchar THEN count(*)
               ELSE NULL::bigint
           END AS count
      FROM event event
     WHERE event.action = ANY (ARRAY['ATTACK'::bpchar, 'CONQUER'::bpchar])
     GROUP BY event.player_id_2, event.action) against_player ON against_player.round_id = round.round_id
  GROUP BY round.round_id;






CREATE TABLE round_stats
(
  round_id integer NOT NULL,
  avg_damage_taken integer,
  avg_damage_done integer,
  avg_planets_conquered integer,
  avg_planets_lost integer,
  avg_ships_built integer,
  avg_ships_lost integer,
  avg_ship_upgrades bigint,
  avg_fuel_mined bigint,
  avg_distance_travelled bigint,
  CONSTRAINT pk_round_stats PRIMARY KEY (round_id)
)
WITH (
  OIDS=FALSE
);






CREATE OR REPLACE FUNCTION round_control()
  RETURNS boolean AS
$BODY$
DECLARE
	new_planet record;
	trophies RECORD;
	players RECORD;
	p RECORD;
BEGIN

	IF NOT SESSION_USER = 'schemaverse' THEN
		RETURN 'f';
	END IF;	

	IF NOT GET_CHAR_VARIABLE('ROUND_START_DATE')::date <= 'today'::date - GET_CHAR_VARIABLE('ROUND_LENGTH')::interval THEN
		RETURN 'f';
	END IF;


	UPDATE round_stats SET
        	avg_damage_taken = current_round_stats.avg_damage_taken,
                avg_damage_done = current_round_stats.avg_damage_done,
                avg_planets_conquered = current_round_stats.avg_planets_conquered,
                avg_planets_lost = current_round_stats.avg_planets_lost,
                avg_ships_built = current_round_stats.avg_ships_built,
                avg_ships_lost = current_round_stats.avg_ships_lost,
                avg_ship_upgrades =current_round_stats.avg_ship_upgrades,
                avg_fuel_mined = current_round_stats.avg_fuel_mined
        FROM current_round_stats
        WHERE round_stats.round_id=(SELECT last_value FROM round_seq);

	FOR players IN SELECT * FROM player LOOP
		UPDATE player_round_stats SET 
			damage_taken = least(2147483647, current_player_stats.damage_taken),
			damage_done = least(2147483647,current_player_stats.damage_done),
			planets_conquered = least(32767,current_player_stats.planets_conquered),
			planets_lost = least(32767,current_player_stats.planets_lost),
			ships_built = least(32767,current_player_stats.ships_built),
			ships_lost = least(32767,current_player_stats.ships_lost),
			ship_upgrades =least(2147483647,current_player_stats.ship_upgrades),
			fuel_mined = current_player_stats.fuel_mined,
			last_updated=NOW()
		FROM current_player_stats
		WHERE player_round_stats.player_id=players.id AND current_player_stats.player_id=players.id AND player_round_stats.round_id=(select last_value from round_seq);

		UPDATE player_overall_stats SET 
			damage_taken = player_overall_stats.damage_taken + player_round_stats.damage_taken,
			damage_done = player_overall_stats.damage_done + player_round_stats.damage_done,
			planets_conquered = player_overall_stats.planets_conquered + player_round_stats.planets_conquered,
			planets_lost = player_overall_stats.planets_lost + player_round_stats.planets_lost,
			ships_built = player_overall_stats.ships_built +player_round_stats.ships_built,
			ships_lost = player_overall_stats.ships_lost + player_round_stats.ships_lost,
			ship_upgrades = player_overall_stats.ship_upgrades + player_round_stats.ship_upgrades,
			fuel_mined = player_overall_stats.fuel_mined + player_round_stats.fuel_mined
		FROM player_round_stats
		WHERE player_overall_stats.player_id=player_round_stats.player_id 
			and player_overall_stats.player_id=players.id and player_round_stats.round_id=(select last_value from round_seq);
	END LOOP;


	FOR trophies IN SELECT id FROM trophy WHERE approved='t' ORDER by run_order ASC LOOP
		EXECUTE 'INSERT INTO player_trophy SELECT * FROM trophy_script_' || trophies.id ||'((SELECT last_value FROM round_seq)::integer);';
	END LOOP;

	alter table planet disable trigger all;
	alter table fleet disable trigger all;
	alter table planet_miners disable trigger all;
	alter table ship_flight_recorder disable trigger all;
	alter table ship_control disable trigger all;
	alter table ship disable trigger all;
	alter table event disable trigger all;

	--Deactive all fleets
        update fleet set runtime='0 minutes', enabled='f';

	--add archives of stats and events
	--CREATE TEMP TABLE tmp_current_round_archive AS SELECT (SELECT last_value FROM round_seq), event.* FROM event;
	--EXECUTE 'COPY tmp_current_round_archive TO ''/hell/schemaverse_round_' || (SELECT last_value FROM round_seq) || '.csv''  WITH DELIMITER ''|''';

	--Delete everything else
        DELETE FROM planet_miners;
        DELETE FROM ship_flight_recorder;
        DELETE FROM ship_control;
        DELETE FROM ship;
        DELETE FROM event;
        delete from planet WHERE id != 1;

	UPDATE fleet SET last_script_update_tic=0;

        alter sequence event_id_seq restart with 1;
        alter sequence ship_id_seq restart with 1;
        alter sequence tic_seq restart with 1;
	alter sequence planet_id_seq restart with 2;


	--Reset player resources
        UPDATE player set balance=10000, fuel_reserve=100000 WHERE username!='schemaverse';
    	UPDATE fleet SET runtime='1 minute', enabled='t' FROM player WHERE player.starting_fleet=fleet.id AND player.id=fleet.player_id;
 

	UPDATE planet SET fuel=20000000 WHERE id=1;

	WHILE (SELECT count(*) FROM planet) < (SELECT count(*) FROM player) * 1.05 LOOP
		FOR new_planet IN SELECT
			nextval('planet_id_seq') as id,
			CASE (RANDOM() * 11)::integer % 12
			WHEN 0 THEN 'Aethra_' || generate_series
                         WHEN 1 THEN 'Mony_' || generate_series
                         WHEN 2 THEN 'Semper_' || generate_series
                         WHEN 3 THEN 'Voit_' || generate_series
                         WHEN 4 THEN 'Lester_' || generate_series 
                         WHEN 5 THEN 'Rio_' || generate_series 
                         WHEN 6 THEN 'Zergon_' || generate_series 
                         WHEN 7 THEN 'Cannibalon_' || generate_series
                         WHEN 8 THEN 'Omicron Persei_' || generate_series
                         WHEN 9 THEN 'Urectum_' || generate_series
                         WHEN 10 THEN 'Wormulon_' || generate_series
                         WHEN 11 THEN 'Kepler_' || generate_series
			END as name,
                GREATEST((RANDOM() * 100)::integer, 30) as mine_limit,
                GREATEST((RANDOM() * 1000000000)::integer, 100000000) as fuel,
                GREATEST((RANDOM() * 10)::integer,2) as difficulty,
		point(
                CASE (RANDOM() * 1)::integer % 2
                        WHEN 0 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR'))::integer 
                        WHEN 1 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR') * -1)::integer
		END,
                CASE (RANDOM() * 1)::integer % 2
                        WHEN 0 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR'))::integer
                        WHEN 1 THEN (RANDOM() * GET_NUMERIC_VARIABLE('UNIVERSE_CREATOR') * -1)::integer		
		END) as location
		FROM generate_series(1,500)
		LOOP
			if not exists (select 1 from planet where (location <-> new_planet.location) <= 3000) then
				INSERT INTO planet(id, name, mine_limit, difficulty, fuel, location, location_x, location_y)
					VALUES(new_planet.id, new_planet.name, new_planet.mine_limit, new_planet.difficulty, new_planet.fuel, new_planet.location,new_planet.location[0],new_planet.location[1]);
			END IF;	
		END LOOP;
	END LOOP;

	UPDATE planet SET conqueror_id=NULL WHERE planet.id = 1;
	FOR p IN SELECT player.id as id FROM player ORDER BY player.id LOOP
		UPDATE planet SET conqueror_id=p.id, mine_limit=30, fuel=500000000, difficulty=2 
			WHERE planet.id = (SELECT id FROM planet WHERE planet.id != 1 AND conqueror_id IS NULL ORDER BY RANDOM() LIMIT 1);
	END LOOP;

	alter table event enable trigger all;
	alter table planet enable trigger all;
	alter table fleet enable trigger all;
	alter table planet_miners enable trigger all;
	alter table ship_flight_recorder enable trigger all;
	alter table ship_control enable trigger all;
	alter table ship enable trigger all;

	PERFORM nextval('round_seq');

	UPDATE variable SET char_value='today'::date WHERE name='ROUND_START_DATE';


	FOR players IN SELECT * from player WHERE ID <> 0 LOOP
		INSERT INTO player_round_stats(player_id, round_id) VALUES (players.id, (select last_value from round_seq));
	END LOOP;
	INSERT INTO round_stats(round_id) VALUES((SELECT last_value FROM round_seq));

        RETURN 't';
END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;






CREATE INDEX event_toc_index ON event USING btree (toc);

CREATE INDEX ship_location_index ON ship USING GIST (location);
CREATE INDEX planet_location_index ON planet USING GIST (location);

CREATE INDEX ship_player ON ship USING btree (player_id);
CREATE INDEX ship_health ON ship USING btree (current_health);
CREATE INDEX ship_fleet ON ship USING btree (fleet_id);
CREATE INDEX ship_loc_only ON ship USING gist (CIRCLE(location,1));
CREATE INDEX ship_loc_range ON ship USING gist (CIRCLE(location,range));

CREATE INDEX fleet_player ON fleet USING btree (player_id);
CREATE INDEX event_player ON event USING btree (player_id_1);

CREATE INDEX planet_player ON planet USING btree (conqueror_id);
CREATE INDEX planet_loc_only ON planet USING gist (CIRCLE(location,100000));







REVOKE SELECT ON pg_proc FROM public;
REVOKE SELECT ON pg_proc FROM players;
REVOKE create ON schema public FROM public; 
REVOKE create ON schema public FROM players;

REVOKE ALL ON tic_seq FROM players;
GRANT SELECT ON tic_seq TO players;

REVOKE ALL ON round_seq FROM players;
GRANT SELECT ON round_seq TO players;

REVOKE ALL ON variable FROM players;
GRANT SELECT ON public_variable TO players;
GRANT INSERT ON public_variable TO players;
GRANT UPDATE ON public_variable TO players;
GRANT DELETE ON public_variable TO players;


REVOKE ALL ON player FROM players;
REVOKE ALL ON player_id_seq FROM players;
GRANT SELECT ON my_player TO players;
GRANT UPDATE ON my_player TO players;
GRANT SELECT ON online_players TO players;

REVOKE ALL ON ship_control FROM players;
REVOKE ALL ON ship_flight_recorder FROM players;
GRANT UPDATE ON my_ships TO players;
GRANT SELECT ON my_ships TO players;
GRANT INSERT ON my_ships TO players;
GRANT SELECT ON ships_in_range TO players;
GRANT SELECT ON my_ships_flight_recorder TO players;

REVOKE ALL ON ship FROM players;
REVOKE ALL ON ship_id_seq FROM players;


REVOKE ALL ON planet FROM players;
REVOKE ALL ON planet_id_seq FROM players;
REVOKE ALL ON planet_miners FROM players;
GRANT SELECT ON planets TO players;
GRANT UPDATE ON planets TO players;

REVOKE ALL ON event FROM players;
GRANT SELECT ON my_events TO players;

REVOKE ALL ON fleet FROM players;
REVOKE ALL ON fleet_id_seq FROM players;
GRANT INSERT ON my_fleets TO players;
GRANT SELECT ON my_fleets TO players;
GRANT UPDATE ON my_fleets TO players; 

REVOKE ALL ON price_list FROM players;
GRANT SELECT ON price_list TO players;


REVOKE ALL ON round_stats FROM players;
REVOKE ALL ON player_round_stats FROM players;
REVOKE ALL ON player_overall_stats FROM players;
REVOKE ALL ON current_stats FROM players;
REVOKE ALL ON current_player_stats FROM players;
REVOKE ALL ON current_round_stats FROM players;
GRANT SELECT ON round_stats TO players;
GRANT SELECT ON player_round_stats TO players;
GRANT SELECT ON player_overall_stats TO players;
GRANT SELECT ON current_stats TO players;
GRANT SELECT ON current_player_stats TO players;
GRANT SELECT ON current_round_stats TO players;


REVOKE ALL ON action FROM players;
GRANT SELECT ON action TO players;
GRANT INSERT ON action TO players;
GRANT UPDATE ON action TO players;

REVOKE ALL ON trophy FROM players;
GRANT SELECT ON trophy TO players;
GRANT INSERT ON trophy TO players;
GRANT UPDATE ON trophy TO players;

REVOKE ALL ON player_trophy FROM players;
GRANT SELECT ON player_trophy TO players;

REVOKE ALL ON trophy_case FROM players;
GRANT SELECT ON trophy_case TO players;


