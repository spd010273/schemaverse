SELECT last_value AS tic FROM tic_seq;

SELECT id, username, balance, fuel_reserve  FROM my_player;

WITH tt_miner_count AS
(
    SELECT COUNT(*) AS miners
      FROM my_fleets f
      JOIN my_ships s
        ON s.fleet_id = f.id
     WHERE s.name LIKE 'miner%'
),
tt_capital_count AS
(
    SELECT COUNT(*) AS capital_ships
      FROM my_fleets f
      JOIN my_ships s
        ON s.fleet_id = f.id
     WHERE s.name LIKE 'capital%'
),
tt_explorer_count AS
(
    SELECT COUNT(*) AS explorer_count
      FROM my_ships s
      JOIN my_fleets f
        ON f.id = s.fleet_id
     WHERE s.name LIKE 'explorer%'
)
    SELECT *
      FROM tt_capital_count
CROSS JOIN tt_miner_count
CROSS JOIN tt_explorer_count;

    SELECT name,
           ( 100 * current_health::FLOAT / max_health )::VARCHAR || '%' AS health,
           ( 100 * current_fuel::FLOAT / max_fuel )::VARCHAR || '%' AS fuel
      FROM my_ships
     WHERE current_health < max_health
        OR current_fuel < max_fuel
  ORDER BY name;

CREATE OR REPLACE FUNCTION pg_temp.fn_manage_planet
(
    in_planet_id    INTEGER,
    in_ship_role    INTEGER
)
RETURNS BOOLEAN AS
 $function$
DECLARE
    C_SHIP_COUNT    INTEGER;
    C_MINER         INTEGER;
    C_CAPITAL       INTEGER;
    C_EXPLORER      INTEGER;
    my_player_id    INTEGER;
    my_balance      INTEGER;
    my_ship_count   INTEGER;
    my_fleet        INTEGER;
    my_fleet_name   VARCHAR;
    my_location     POINT;
    my_ship         RECORD;
BEGIN
    -- Constants
    C_SHIP_COUNT := 30;
    C_MINER      := 1;
    C_CAPITAL    := 2;
    C_EXPLORER   := 3;

    SELECT id,
           balance
      INTO my_player_id,
           my_balance
      FROM my_player;

    -- Determine the fleet for this planet and role ( or if we need to create a fleet
    SELECT f.id,
           f.name,
           p.location
      INTO my_fleet,
           my_fleet_name,
           my_location
      FROM my_fleets f
INNER JOIN my_ships s
        ON s.fleet_id = f.id
INNER JOIN planets_in_range pir
        ON pir.ship = s.id
       AND pir.planet = in_planet_id
INNER JOIN planets p
        ON p.id = pir.planet;

    IF NOT FOUND THEN
        -- Create fleet
             SELECT CASE WHEN in_ship_role = C_MINER
                         THEN p.name || '_miners'
                         WHEN in_ship_role = C_CAPITAL
                         THEN p.name || '_capital_ships'
                         WHEN in_ship_role = C_EXPLORER
                         THEN p.name || '_explorers'
                         ELSE p.name || '_bad_func_call'
                          END AS name
               INTO my_fleet_name
               FROM planets p
              WHERE p.id = in_planet_id;

        INSERT INTO my_fleets( name )
             VALUES ( my_fleet_name );

        SELECT id
          INTO my_fleet
          FROM my_fleets
         WHERE name = my_fleet_name;
    END IF;
    
    -- Check to see if we have proper # of ships in fleet
    SELECT COUNT( s.id )
      INTO my_ship_count
      FROM my_ships s
     WHERE s.fleet_id = my_fleet;

    IF ( my_ship_count < C_SHIP_COUNT ) THEN
        -- We have ships to create!
        INSERT INTO my_ships
                    (
                        name,
                        fleet_id,
                        location,
                        attack,
                        defense,
                        engineering,
                        prospecting
                    )
             SELECT CASE WHEN in_ship_role = C_MINER
                         THEN my_fleet_name || '_miner_' || generate_series( 1, C_SHIP_COUNT - my_ship_count )
                         WHEN in_ship_role = C_CAPITAL
                         THEN my_fleet_name || '_capital_' || generate_series( 1, C_SHIP_COUNT - my_ship_count )
                         WHEN in_ship_role = C_EXPLORER
                         THEN my_fleet_name || '_explorer_' || generate_series( 1, C_SHIP_COUNT - my_ship_count )
                         ELSE my_fleet_name || '_unknown_' || generate_series( 1, C_SHIP_COUNT - my_ship_count )
                          END AS name,
                    my_fleet AS fleet_id,
                    my_location AS location,
                    CASE WHEN in_ship_role = C_MINER
                         THEN 0
                         WHEN in_ship_role = C_CAPITAL
                         THEN 8
                         WHEN in_ship_role = C_EXPLORER
                         THEN 7
                         ELSE 5
                          END AS attack,
                    CASE WHEN in_ship_role = C_MINER
                         THEN 0
                         WHEN in_ship_role = C_CAPITAL
                         THEN 8
                         WHEN in_ship_role = C_EXPLORER
                         THEN 7
                         ELSE 5
                          END AS defense,
                    CASE WHEN in_ship_role = C_MINER
                         THEN 2
                         WHEN in_ship_role = C_CAPITAL
                         THEN 4
                         WHEN in_ship_role = C_EXPLORER
                         THEN 5
                         ELSE 5
                          END AS engineering,
                    CASE WHEN in_ship_role = C_MINER
                         THEN 18
                         WHEN in_ship_role = C_CAPITAL
                         THEN 0
                         WHEN in_ship_role = C_EXPLORER
                         THEN 1
                         ELSE 5
                          END AS prospecting;
    END IF;
    -- TODO: Create a temp table with:
    --  ship_role,
    --  upgrde_type ( Ex: PROSPECTING )
    --  max_val
    -- cross join this to automate and allow easy change during runtime
    -- Manage ship upgrades
    IF ( in_ship_role = C_MINER ) THEN
        FOR my_ship IN (
                        SELECT id,
                               prospecting
                          FROM my_ships
                         WHERE fleet_id = my_fleet
                           AND prospecting < 498
                       ) LOOP
            PERFORM UPGRADE( my_ship.id, 'PROSPECTING', 498 - my_ship.prospecting );
        END LOOP;
    ELSIF ( in_ship_role = C_CAPITAL ) THEN
        FOR my_ship IN (
                        SELECT id,
                               attack,
                               defense,
                               engineering,
                               max_health,
                               range
                          FROM my_ships
                         WHERE fleet_id = my_fleet
                           AND (
                                   attack      < 200
                                OR defense     < 200
                                OR engineering < 100
                                OR max_health  < 200
                                OR range       < 300
                               ) 
                       ) LOOP
            PERFORM UPGRADE( my_ship.id, 'ATTACK',      200 - my_ship.attack      ),
                    UPGRADE( my_ship.id, 'DEFENSE',     200 - my_ship.defense     ),
                    UPGRADE( my_ship.id, 'ENGINEERING', 100 - my_ship.engineering ),
                    UPGRADE( my_ship.id, 'MAX_HEALTH',  300 - my_ship.max_health  ),
                    UPGRADE( my_ship.id, 'RANGE',       300 - my_ship.range       );
        END LOOP;
    ELSIF ( in_ship_role = C_EXPLORER ) THEN
        FOR my_ship IN (
                        SELECT id,
                               attack,
                               defense,
                               engineering,
                               max_speed,
                               max_fuel,
                               range,
                               max_health
                          FROM my_ships
                         WHERE fleet_id = my_fleet
                           AND (
                                   attack      < 200
                                OR defense     < 200
                                OR engineering < 99
                                OR max_speed   < 100000
                                OR max_fuel    < 100000
                                OR range       < 300
                                OR max_health  < 300
                               ) 
                       ) LOOP
            PERFORM UPGRADE( my_ship.id, 'ATTACK',      200    - my_ship.attack      ),
                    UPGRADE( my_ship.id, 'DEFENSE',     200    - my_ship.defense     ),
                    UPGRADE( my_ship.id, 'ENGINEERING', 99     - my_ship.engineering ),
                    UPGRADE( my_ship.id, 'RANGE',       300    - my_ship.range       ),
                    UPGRADE( my_ship.id, 'MAX_SPEED',   100000 - my_ship.max_speed   ),
                    UPGRADE( my_ship.id, 'MAX_FUEL',    100000 - my_ship.max_fuel    ),
                    UPGRADE( my_ship.id, 'MAX_HEALTH',  300    - my_ship.max_health  );
        END LOOP;
    ELSE
        RAISE NOTICE 'Illegal ship to upgrade, skipping';
    END IF;

    -- Handle defense
    FOR my_ship IN (
                        SELECT sir.id,
                               sir.ship_in_range_of
                          FROM ships_in_range sir
                          JOIN my_ships s
                            ON s.id = sir.ship_in_range_of
                           AND s.fleet_id = my_fleet
                     ) LOOP
        PERFORM ATTACK( my_ship.ship_in_range_of, my_ship.id );
    END LOOP;

    -- Handle healing, refueling
    FOR my_ship IN (
                        SELECT s.id,
                               (s.max_health - s.current_health) AS repair
                          FROM my_ships s
                         WHERE s.fleet_id = my_fleet
                           AND s.max_health > s.current_health
                   ) LOOP
        PERFORM REPAIR( id, my_ship.id )
           FROM my_ships
          WHERE fleet_id = my_fleet;
    END LOOP;

    FOR my_ship IN (
                        SELECT id
                          FROM my_ships
                         WHERE current_fuel < max_fuel
                   ) LOOP
        PERFORM REFUEL_SHIP( my_ship.id );
    END LOOP;
    
    -- Handle mining
    PERFORM MINE( r.ship, r.planet )
       FROM planets_in_range r
       JOIN my_ships s
         ON s.id = r.ship
        AND s.fleet_id = my_fleet
        AND s.prospecting > 0
        AND r.distance < s.range;
    -- TODO: Handle explorers and their navigation

    RETURN TRUE;
END
 $function$
    LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION pg_temp.fn_create_capital_ships
(
    in_planet_id    INTEGER
)
RETURNS BOOLEAN AS
 $function$
BEGIN
    RETURN pg_temp.fn_manage_planet( in_planet_id, 2 );
END
 $function$
    LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION pg_temp.fn_create_miners
(
    in_planet_id    INTEGER
)
RETURNS BOOLEAN AS
 $function$
BEGIN
    RETURN pg_temp.fn_manage_planet( in_planet_id, 1 );
END
 $function$
    LANGUAGE 'plpgsql';


-- Mining and defense handler
DO $$
DECLARE
    attackers           RECORD;
    to_repair           RECORD;
    my_balance          INTEGER;
    my_repair_amount    INTEGER;
    my_closest_planet   RECORD;
    my_fuel             INTEGER;
    my_average_dist     FLOAT;
    my_planet           RECORD;
    my_new_planet_count INTEGER;
    my_ship_role        RECORD;
    my_conq             RECORD;
    my_seq_start        INTEGER;
    my_fleet            RECORD;
BEGIN
   -- Attempt to repair any damaged ships
   FOR to_repair IN ( SELECT id, current_health, fleet_id FROM my_ships WHERE current_health < max_health ) LOOP
       my_repair_amount := 0; 
       IF( to_repair.current_health = 0 ) THEN
           WITH tt_functional_ships AS
           (
                SELECT s.id
                  FROM my_ships s
                 WHERE s.action_target_id IS NULL
                   AND s.fleet_id = to_repair.fleet_id
              ORDER BY s.engineering DESC
           )
               SELECT SUM( REPAIR( tt.id, to_repair.id ) )
                 INTO my_repair_amount
                 FROM tt_functional_ships tt;
        ELSE
            SELECT REPAIR( to_repair.id, to_repair.id )
              INTO my_repair_amount;
        END IF;
        
        RAISE NOTICE 'Ship % Repaired % health', to_repair.id, my_repair_amount;
   END LOOP;

   PERFORM MINE( r.ship, r.planet )
      FROM planets_in_range r
      JOIN my_ships s
        ON s.id = r.ship
       AND s.name ILIKE 'miner%'
       AND r.distance = 0;
    
    FOR attackers IN (
                        SELECT sir.id,
                               sir.ship_in_range_of
                          FROM ships_in_range sir
                          JOIN my_ships s
                            ON s.id = sir.ship_in_range_of
                           AND ( 
                                    s.name ILIKE 'capital%'
                                 OR s.name ILIKE 'explorer%'
                               )
                     ) LOOP
        PERFORM ATTACK( attackers.ship_in_range_of, attackers.id );
    END LOOP;
    
    -- Determine closest planet to rape and pillage
    WITH tt_my_planets AS
    (
        SELECT id,
               location,
               location_x,
               location_y
          FROM planets
         WHERE conqueror_id = get_player_id( 'spd010273' )
    ),
    tt_closest_planets AS
    (
        SELECT p.id,
               p.location,
               sqrt( ( p.location_x - tt.location_x )^2 + ( p.location_y - tt.location_y )^2 ) AS distance
          FROM planets p
    CROSS JOIN tt_my_planets tt
         WHERE p.id NOT IN( SELECT id FROM tt_my_planets )
    )
        SELECT id,
               location,
               distance
          INTO my_closest_planet
          FROM tt_closest_planets
         WHERE distance > 0
      ORDER BY distance ASC
         LIMIT 1;

    RAISE NOTICE 'Closest planet % is % units away', my_closest_planet.id, my_closest_planet.distance;
    
    -- Refuel
    PERFORM refuel_ship( id )
       FROM my_ships
      WHERE current_fuel < max_fuel;
    
    SELECT fuel_reserve
      INTO my_fuel
      FROM my_player;
    
    SELECT balance
      INTO my_balance
      FROM my_player;

    -- Convert extra fuel to money, leaving a nice 150k reserve
    IF( my_fuel > 160000 ) THEN
        PERFORM CONVERT_RESOURCE( 'FUEL', my_fuel - 160000 );
    END IF;
    
    SELECT AVG( p.location <-> s.location )::FLOAT
      INTO my_average_dist
      FROM my_ships s
INNER JOIN planets p
        ON ( p.location <-> s.destination ) < 0.01
     WHERE s.name ILIKE 'explorer%';

    IF( my_average_dist < 300 ) THEN --default range
        RAISE NOTICE 'Attempting to Conquor planet...';
         
       FOR my_conq IN (
        SELECT MINE( r.ship, r.planet ) AS result,
               r.ship AS id
          FROM planets_in_range r
          JOIN my_ships s
            ON s.id = r.ship
           AND s.name ILIKE 'explorer%'
                      ) LOOP
            IF( my_conq.result ) THEN
                RAISE NOTICE 'Ship % mined it!', my_conq.id;
            ELSE
                RAISE NOTICE 'Ship % failed to conquor!', my_conq.id;
            END IF;
        END LOOP;
    END IF;
    my_new_planet_count := 0;

    --Detect if we have a newly conquored planet
    FOR my_planet IN (
                        SELECT p.id,
                               p.location
                          FROM planets p
                     LEFT JOIN planets_in_range pir
                            ON pir.planet = p.id
                         WHERE p.conqueror_id = get_player_id( 'spd010273' )
                           AND pir.ship IS NULL
                     ) LOOP
    -- Create mining fleet
        my_new_planet_count := my_new_planet_count + 1; 
        
        WITH tt_stripped AS
        (
            SELECT regexp_replace( name, 'capital', '' )::INTEGER AS id
              FROM my_ships
             WHERE name LIKE 'capital%'
        ) 
            SELECT MAX( id ) + 1
              INTO my_seq_start
              FROM tt_stripped;
        
        WITH tt_fleet AS
        (
        INSERT INTO my_fleets( name )
             SELECT p.name || ' Miners'
               FROM planets p
              WHERE p.id = my_planet.id
        )
            SELECT id
              INTO my_fleet
              FROM my_fleets
             WHERE name = ( SELECT name FROM planets WHERE id = my_planet.id ) || ' Miners';
        
        WITH tt_ids AS
        (
            SELECT generate_series( my_seq_start, my_seq_start + 29 ) AS id
        )
        INSERT INTO my_ships
                    (
                        name,
                        attack,
                        defense,
                        prospecting,
                        engineering,
                        location,
                        fleet_id
                    )
             SELECT 'miner' || id AS name,
                    1,
                    1,
                    17,
                    1,
                    my_planet.location,
                    my_fleet.id
               FROM tt_ids;
        -- This will cost 8k

        PERFORM UPGRADE( id, 'PROSPECTING', 480 ) --6400
          FROM my_ships
         WHERE name LIKE 'miner%'
           AND fleet_id = my_fleet.id;

        WITH tt_fleet AS
        (
        INSERT INTO my_fleets( name )
             SELECT p.name || ' Capital Ships'
               FROM planets p
              WHERE p.id = my_planet.id
        )
            SELECT id
              INTO my_fleet
              FROM my_fleets
             WHERE name = ( SELECT name FROM planets WHERE id = my_planet.id ) || ' Capital Ships';

        WITH tt_ids AS
        (
            SELECT generate_series( my_seq_start, my_seq_start + 29 ) AS id
        )
        INSERT INTO my_ships
                    (
                        name,
                        attack,
                        defense,
                        prospecting,
                        engineering,
                        location,
                        fleet_id
                    )
             SELECT 'capital' || id AS name,
                    8,
                    8,
                    0,
                    4,
                    my_planet.location,
                    my_fleet.id
               FROM tt_ids;
        -- This will cost 8k

       PERFORM UPGRADE( id, 'ATTACK', 32 ), --6400
               UPGRADE( id, 'DEFENSE', 32 ),
               UPGRADE( id, 'ENGINEERING', 36 )
          FROM my_ships
         WHERE name LIKE 'capital%'
           AND fleet_id = my_fleet.id;
    END LOOP;
   
    -- This will hopefully keep the explorers at the new planet until we can colonize 
    IF ( my_new_planet_count < 1 ) THEN 
        PERFORM SHIP_COURSE_CONTROL
                (
                    id,
                    max_speed,
                    NULL,
                    my_closest_planet.location
                )
           FROM my_ships
          WHERE name LIKE 'explorer%';
    END IF;
    
    -- Attempt to maintain populations at conquored planets
    FOR my_planet IN(
                        SELECT p.id, p.location, p.mine_limit
                          FROM planets p
                         WHERE p.conqueror_id = get_player_id( 'spd010273' )
                    ) LOOP
       FOR my_ship_role IN (
        SELECT COUNT( s.id ),
               array_to_string( array_agg( distinct p.mine_limit ), ',')::INTEGER AS mine_limit,
               my_planet.id,
               s.fleet_id,
               array_to_string( array_agg( DISTINCT regexp_replace( s.name, '\d', '', 'g' ) ), ',' ) AS name
          FROM my_ships s
          JOIN planets_in_range pir
            ON pir.ship = s.id
          JOIN planets p
            ON p.id = pir.planet
           AND p.id = my_planet.id
      GROUP BY s.fleet_id
                        ) LOOP
            IF( my_ship_role.name = 'miner' ) THEN
            ELSIF( my_ship_role.name = 'capital' ) THEN
            
            END IF; 
        END LOOP;
    END LOOP;
END $$;

-- Explorer status
    SELECT DISTINCT
           ( 100 * s.speed::FLOAT / s.max_speed )::VARCHAR || '%' AS speed,
           s.direction,
           p.name AS destination_planet,
           p.id AS planet_id,
           p.location <-> s.location AS distance_remaining
      FROM my_ships s
INNER JOIN planets p
        ON ( p.location <-> s.destination ) < 0.01
     WHERE s.name LIKE 'explorer%';

SELECT COUNT(*) AS planet_count FROM planets WHERE conqueror_id = get_player_id( 'spd010273' );
