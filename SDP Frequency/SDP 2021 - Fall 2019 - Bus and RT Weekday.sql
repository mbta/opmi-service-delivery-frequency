-- V11.2
-- This version differs from V11.1 in that it rounds the average expected wait time to the nearest minute (rather than tenth of a minute)
-- This follows the standard for the CTPS methodology and was discussed as a way to increase leniency when going over the "soft pass" option
-- It makes a notable difference in category-level results for Community Bus in Autumn Twenty-Eighteen

/**
This version includes parameters.
The script has been written where you can run a find and replace for: rating season-year, gtfs recap season, gtfs recap year, day type, and SDP version
It is recommended that you manually review Step 1 and Step 2 once you do this to make sure all parameters are set properly (especially schedule start/end dates)
Care has been taken to make sure no parameter keywords appear elsewhere in the script (years are spelt out and alternative names are used for ratings)
Please follow this convention if updating this script, thank you!
**/

-- Once the script is run, the following tables will provide you with intermediate and final results:
-- Export "typical_flag" for frequency and typicality information at the stop level
-- SELECT * FROM typical_flag;
-- Export "equity" for full detail on each route/direction/time period
-- SELECT * FROM equity;
-- Export "freq_bus_rt_summary" for a rolled up view by SDP route description (for reporting)
-- SELECT * FROM freq_bus_rt_summary;
-- Export "daily_accept" for each route's status as acceptable/unacceptable based on a 95% passing threshold
-- SELECT * FROM daily_accept;

-----------------------------------------------------------------------
-- STEP 1: DETERMINE START/END DATE PARAMETERS
-- Find your start/end dates for the rating and day type you want
SELECT DISTINCT r.route_desc, c.start_date, c.end_date, ca.service_description, ca.service_schedule_name
FROM gtfs_recap.trips_2019_fall_recap t
JOIN gtfs_recap.routes_2019_fall_recap r ON t.route_id = r.route_id
JOIN gtfs_recap.stop_times_2019_fall_recap st ON t.trip_id = st.trip_id
JOIN gtfs_recap.calendar_attributes_2019_fall_recap ca ON t.service_id = ca.service_id
JOIN gtfs_recap.calendar_2019_fall_recap c ON t.service_id = c.service_id
WHERE 
	r.route_desc IN ('Local Bus', 'Key Bus', 'Community Bus', 'Rapid Transit') 
	AND LOWER(ca.service_description) = 'weekday schedule'
ORDER BY route_desc;


-----------------------------------------------------------------------
-- STEP 2: DECLARE YOUR PARAMETERS
-- Change the text below
DROP TABLE IF EXISTS parameters;
CREATE TEMP TABLE parameters AS
SELECT
	 '2021' AS sdp_version
	,'fall 2019' AS rating
	,'weekday schedule' AS service_description
	,'weekday' AS day_type
	,'2019-09-15'::DATE AS start_date
	,'2019-12-15'::DATE AS end_date;

-- In the code blocks below, change the GTFS partition to the rating you want to evaluate
DROP TABLE IF EXISTS gtfs_trips;
CREATE TEMP TABLE gtfs_trips AS
SELECT * FROM gtfs_recap.trips_2019_fall_recap;

DROP TABLE IF EXISTS gtfs_multi_route_trips;
CREATE TEMP TABLE gtfs_multi_route_trips AS
SELECT * FROM gtfs_recap.multi_route_trips_2019_fall_recap;

DROP TABLE IF EXISTS gtfs_routes;
CREATE TEMP TABLE gtfs_routes AS
SELECT * FROM gtfs_recap.routes_2019_fall_recap;

DROP TABLE IF EXISTS gtfs_stop_times;
CREATE TEMP TABLE gtfs_stop_times AS
SELECT * FROM gtfs_recap.stop_times_2019_fall_recap st;

DROP TABLE IF EXISTS gtfs_stops;
CREATE TEMP TABLE gtfs_stops AS
SELECT * FROM gtfs_recap.stops_2019_fall_recap;

DROP TABLE IF EXISTS gtfs_calendar_attributes;
CREATE TEMP TABLE gtfs_calendar_attributes AS
SELECT * FROM gtfs_recap.calendar_attributes_2019_fall_recap;

DROP TABLE IF EXISTS gtfs_calendar;
CREATE TEMP TABLE gtfs_calendar AS
SELECT * FROM gtfs_recap.calendar_2019_fall_recap;


-----------------------------------------------------------------------
-- STEP 3: RUN QUERY TO CALCULATE

-- First we will take all the trips in the rating and clean their associated route IDs
-- Some trips are credited to more than one route; we need to make this duplication happen before we move on
DROP TABLE IF EXISTS robust_trips;
CREATE TEMP TABLE robust_trips AS
SELECT 
	 t.trip_id
	,t.direction_id
	,t.service_id
	,CASE
		WHEN m.added_route_id IS NOT NULL THEN m.added_route_id -- if the trip is credited to more than one route, recognize this
		ELSE r.route_id -- else just take the plain, single route ID
		END AS route_id
FROM gtfs_trips t
LEFT JOIN gtfs_routes r 
	ON t.route_id = r.route_id
LEFT JOIN gtfs_multi_route_trips m
	ON t.trip_id = m.trip_id;


-- Now we get all of the events of modes relevant to the headway standards
-- We line them up with their SDP route IDs, since the route IDs in GTFS may vary
-- We are not concerned with aligning late night (midnight to 3AM) arrival times with the 24-hour clock because this is outside span (was an issue on SL in Autumn Twenty-Eighteen recap)
DROP TABLE IF EXISTS all_events_full;
CREATE TEMP TABLE all_events_full AS
SELECT
	 st.arrival_time
	,sdpr.sdp_route_id
	,rc.sdp_route_desc
	,r.route_desc AS gtfs_route_desc
	,t.direction_id
	,t.trip_id
	,CASE
		 WHEN s.parent_station IS NULL THEN st.stop_id
		 ELSE s.parent_station END AS master_stop_id
	,st.checkpoint_id
	,sdpt.rpt_timeperiod_id
	,sdpt.sdp_timeperiod_desc
	-- The following case statements account for where the required span does not line up perfectly with the time period
	-- This is important for Community Bus and weekend calculation
	,CASE 
		WHEN ss.span_start BETWEEN sdpt.timeperiod_start AND sdpt.timeperiod_end THEN ss.span_start
		ELSE sdpt.timeperiod_start END AS timeperiod_start
	,CASE
		WHEN ss.span_end BETWEEN sdpt.timeperiod_start AND sdpt.timeperiod_end THEN ss.span_end
		ELSE sdpt.timeperiod_end END AS timeperiod_end
-- join together all relevant gtfs tables
FROM robust_trips t
LEFT JOIN gtfs_routes r 
	ON t.route_id = r.route_id
LEFT JOIN gtfs_stop_times st 
	ON t.trip_id = st.trip_id
LEFT JOIN gtfs_stops s 
	ON st.stop_id = s.stop_id
LEFT JOIN gtfs_calendar_attributes ca 
	ON t.service_id = ca.service_id
LEFT JOIN gtfs_calendar c 
	ON t.service_id = c.service_id
-- then join gtfs into the sdp framework
CROSS JOIN parameters p
LEFT JOIN sdp.routes_to_gtfs rtg 
	ON rtg.sdp_version = p.sdp_version 
	AND rtg.gtfs_route_id = r.route_id -- convert the gtfs route id to the sdp_route_id
LEFT JOIN sdp.routes sdpr -- attach the most granular route category available
	ON sdpr.sdp_version = p.sdp_version 
	AND rtg.sdp_route_id = sdpr.sdp_route_id 
LEFT JOIN sdp.route_categories rc -- join by this granular category to broader ones, as well as info on where to pull context data
	ON rc.sdp_version = p.sdp_version 
	AND LOWER(rc.rating) = LOWER(p.rating )
	AND sdpr.route_category = rc.route_category
LEFT JOIN sdp.timeperiod sdpt -- assign each stop event to its appropriate time period
	ON sdpt.sdp_version = p.sdp_version 
	AND LOWER(sdpt.daytype) = LOWER(p.day_type)
	AND sdpt.sdp_mode = rc.sdp_mode 
	AND st.arrival_time BETWEEN timeperiod_start AND timeperiod_end
LEFT JOIN sdp.spanofservice ss
	ON ss.sdp_version = p.sdp_version
	AND ss.sdp_route_desc = rc.sdp_route_desc
	AND ss.sdp_daytype = p.day_type
WHERE
	rc.sdp_route_desc IN ('Local Bus', 'Key Bus', 'Community Bus', 'Rapid Transit') -- Only include bus and RT service (note that this filters the label in the SDP table.  You can be another route type like supplemental in GTFS and still be calculated as a piece of another route)
	AND LOWER(ca.service_description) = LOWER(p.service_description)
	AND c.start_date::DATE <= p.start_date 
	AND c.end_date::DATE >= p.end_date -- Only include schedules that spanned the entire rating, as determined above	
	AND st.arrival_time BETWEEN ss.span_start AND ss.span_end; -- Only include stop events within span (span is sometimes misaligned with time periods)
	
SELECT * FROM all_events_full LIMIT 100;


-- Now we check for all the stops in the relevant services that were marked as timepoints in each route/direction/time period
DROP TABLE IF EXISTS find_timepoints;
CREATE TEMP TABLE find_timepoints AS
SELECT DISTINCT
	 sdp_route_id
	,direction_id
	,rpt_timeperiod_id
	,master_stop_id
FROM all_events_full
WHERE checkpoint_id IS NOT NULL;

SELECT * FROM find_timepoints;


-- Rapid Transit routes, as well as some bus routes, do not have timepoints
-- We need to be able to identify these instances systematically
-- To be robust, we are keeping this at the route/direction/time period level; though it is unlikely a route will have timepoints for only PART of the day

-- First get a table with all the distinct route/direction/time periods in this rating
DROP TABLE IF EXISTS all_units;
CREATE TEMP TABLE all_units AS
SELECT DISTINCT
	 sdp_route_id
	,direction_id
	,rpt_timeperiod_id
FROM all_events_full;

SELECT * FROM all_units ORDER BY sdp_route_id, direction_id, rpt_timeperiod_id;


-- Now find the route/direction/time periods that do not have any timepoints listed in GTFS
DROP TABLE IF EXISTS no_timepoints;
CREATE TEMP TABLE no_timepoints AS
SELECT
	 u.sdp_route_id
	,u.direction_id
	,u.rpt_timeperiod_id
FROM all_units u
LEFT JOIN find_timepoints t ON u.sdp_route_id = t.sdp_route_id AND u.direction_id = t.direction_id AND u.rpt_timeperiod_id = t.rpt_timeperiod_id
WHERE t.master_stop_id IS NULL
ORDER BY sdp_route_id, direction_id, rpt_timeperiod_id;

SELECT * FROM no_timepoints ORDER BY sdp_route_id, direction_id, rpt_timeperiod_id;


----------------------------------------------
-- Now we need to restrict the all_events_full table only to stop we want to consider (all stops for routes without timepoints, otherwise consider timepoints only)
DROP TABLE IF EXISTS all_events;
CREATE TEMP TABLE all_events AS
-- Take only events where the route/direction/timeperiod/stop could be found in the timepoints table
SELECT e.*
FROM all_events_full e
INNER JOIN find_timepoints t 
	ON e.sdp_route_id = t.sdp_route_id 
	AND e.master_stop_id = t.master_stop_id
	AND e.direction_id = t.direction_id
	AND e.rpt_timeperiod_id = t.rpt_timeperiod_id
-- Then append all the stops on routes that have no timepoints
UNION ALL
SELECT e.*
FROM all_events_full e
INNER JOIN no_timepoints nt
	ON e.sdp_route_id = nt.sdp_route_id
	AND e.direction_id = nt.direction_id
	AND e.rpt_timeperiod_id = nt.rpt_timeperiod_id;
	
-- Note that not all stop events in this table have to have been a timepoint for THAT service, just for a service under that SDP route ID at some point in the period/direction
-- For example, the 116 will be evaluated for any timepoint on the 117.  A trip on the 10 that does not consider stop x to be a timepoint will still evaluate it as such if at least one other trip on the 10 did so. 
SELECT * FROM all_events WHERE checkpoint_id IS NULL;


-- We want to do two rounds of cleaning here
---- Take out stops on the same trip scheduled for different times (loops); only consider the first stop event
---- Take out stops on different trips scheduled for the same minute (0 headway, no value to riders)

-- First take out the loops, considering the trip ID
DROP TABLE IF EXISTS no_loops;
CREATE TEMP TABLE no_loops AS
SELECT
	 MIN(arrival_time) AS arrival_time
	,sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,timeperiod_start
	,timeperiod_end
FROM all_events
GROUP BY sdp_route_id, sdp_route_desc, direction_id, trip_id, master_stop_id, rpt_timeperiod_id, sdp_timeperiod_desc, timeperiod_start, timeperiod_end;

SELECT * FROM no_loops LIMIT 10;

-- Now take out where multiple stop events create a zero headway at a stop (no benefit to riders)
DROP TABLE IF EXISTS no_duplicates;
CREATE TEMP TABLE no_duplicates AS
SELECT DISTINCT
	 arrival_time
	,sdp_route_id
	,sdp_route_desc
	,direction_id
--	,trip_id -- trip ID no longer relevant because we already removed loops.  Now we want to check where multiple trips on the same route meet up at a stop
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,timeperiod_start
	,timeperiod_end
FROM no_loops;

SELECT * FROM no_duplicates LIMIT 10;


---------------------------------------------------------
-- Now we begin assigning typicality to the timepoints/stops (this is the first part of the process)

-- The table below will count the number of times each stop on the route is served throughout the day
DROP TABLE IF EXISTS count_service;
CREATE TEMP TABLE count_service AS
SELECT sdp_route_id, master_stop_id, direction_id, sdp_timeperiod_desc, COUNT(*) AS stop_count
FROM no_duplicates
GROUP BY sdp_route_id, master_stop_id, direction_id, sdp_timeperiod_desc
ORDER BY sdp_route_id, direction_id, sdp_timeperiod_desc, stop_count DESC;

SELECT * FROM count_service;


-- Now we need to compare each stop on the route to the most-served stop in each direction
DROP TABLE IF EXISTS percent_to_max;
CREATE TEMP TABLE percent_to_max AS
SELECT
		 *
		,FIRST_VALUE(stop_count) OVER (PARTITION BY sdp_route_id, direction_id, sdp_timeperiod_desc ORDER BY stop_count DESC) AS max_count_for_direction
		,ROUND(stop_count/FIRST_VALUE(stop_count) OVER (PARTITION BY sdp_route_id, direction_id, sdp_timeperiod_desc ORDER BY stop_count DESC)::NUMERIC, 2) AS stop_percent_to_max
FROM count_service;

SELECT * FROM percent_to_max ORDER BY sdp_route_id, direction_id, sdp_timeperiod_desc, stop_percent_to_max DESC;


----------------------------------------------------------
-- Set up the lag between stop events
DROP TABLE IF EXISTS all_events_lag;
CREATE TEMP TABLE all_events_lag AS
SELECT
    sdp_route_id
   ,sdp_route_desc
   ,direction_id
   ,master_stop_id 
   ,arrival_time
   ,rpt_timeperiod_id
   ,sdp_timeperiod_desc
   ,timeperiod_start
   ,timeperiod_end
   ,LAG(arrival_time,1) OVER (
      PARTITION BY sdp_route_id, sdp_route_desc, master_stop_id, direction_id, rpt_timeperiod_id, sdp_timeperiod_desc
      ORDER BY arrival_time
   ) previous_arrival
FROM
   no_duplicates;
   
SELECT * FROM all_events_lag LIMIT 10;


-- Now we get the headway at each stop
-- Join in the targets.  If no target exists, the inner join will eliminate the stop event record
DROP TABLE IF EXISTS headways;
CREATE TEMP TABLE headways AS
SELECT
    e.sdp_route_id
   ,e.sdp_route_desc
   ,e.direction_id
   ,e.master_stop_id
   ,e.arrival_time
   ,e.rpt_timeperiod_id
   ,e.sdp_timeperiod_desc
   ,e.timeperiod_start
   ,e.timeperiod_end
   ,fb.benchmark
   ,EXTRACT(MINUTE FROM (e.arrival_time::interval - e.previous_arrival::interval)) + (EXTRACT(HOUR FROM (e.arrival_time::interval - e.previous_arrival::interval)) * 60) AS headway_minutes
FROM all_events_lag e
CROSS JOIN parameters p
INNER JOIN sdp.freq_benchmarks fb 
	ON fb.sdp_version = p.sdp_version
	AND fb.daytype = p.day_type
	AND fb.sdp_route_desc = e.sdp_route_desc 
	AND fb.sdp_timeperiod_desc = e.sdp_timeperiod_desc;

SELECT * FROM headways LIMIT 10;



-------------------------------------------------------------
-- Now we are going to find the gaps between the boundaries of the time period and the start/end of service at the stop

-- Find the first and last stop event time for each stop, route, direction, and time period
-- Attach this value to all the stop event records (we use the headway table because it is already restricted to where benchmarks exists)
DROP TABLE IF EXISTS calculate_first_last;
CREATE TEMP TABLE calculate_first_last AS
SELECT
	 sdp_route_id, sdp_route_desc, direction_id, master_stop_id, arrival_time, rpt_timeperiod_id, sdp_timeperiod_desc, timeperiod_start, timeperiod_end, benchmark
	,MIN(arrival_time) OVER (PARTITION BY sdp_route_id, direction_id, master_stop_id, sdp_timeperiod_desc) AS first_arrival
	,MAX(arrival_time) OVER (PARTITION BY sdp_route_id, direction_id, master_stop_id, sdp_timeperiod_desc) AS last_arrival
FROM headways;

SELECT * FROM calculate_first_last LIMIT 10;


-- Now we restrict this table only to where the stop event is the first or last (or both) at that station for that route/direction/time period
-- With these records we calculate the raw gaps between the start/end of service and the period boundaries
DROP TABLE IF EXISTS gap_calculation;
CREATE TEMP TABLE gap_calculation AS
SELECT 
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,arrival_time
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,timeperiod_start
	,timeperiod_end
	,benchmark
	,first_arrival
	,last_arrival
	,CASE 
	 WHEN arrival_time = first_arrival 
	 THEN EXTRACT(MINUTE FROM (arrival_time::interval - timeperiod_start::interval)) + (EXTRACT(HOUR FROM (arrival_time::interval - timeperiod_start::interval)) * 60)
	 ELSE NULL
	 END AS starting_headway
	,CASE 
	 WHEN arrival_time = last_arrival 
	 THEN EXTRACT(MINUTE FROM (timeperiod_end::interval - arrival_time::interval)) + (EXTRACT(HOUR FROM (timeperiod_end::interval - arrival_time::interval)) * 60)
	 ELSE NULL
	 END AS ending_headway
FROM calculate_first_last
WHERE arrival_time = first_arrival OR arrival_time = last_arrival;

-- Some stop events are both the first and the last
SELECT * FROM gap_calculation WHERE starting_headway IS NOT NULL AND ending_headway IS NOT NULL;


-- Now we look at the gaps and we calculate the artificial headways we will have available to adjust the raw headways between stop events
-- If your gap was within the target, we are willing to credit you the target value
-- If your gap was above the target, then we will penalize you for the full value of that gap
-- This table will be the reference for these penalty/credit values
DROP TABLE IF EXISTS buffers;
CREATE TEMP TABLE buffers AS
SELECT
	 *
	,CASE
	 WHEN starting_headway <= benchmark THEN benchmark
	 ELSE starting_headway END AS artificial_start_buffer
	,CASE
	 WHEN ending_headway <= benchmark THEN benchmark
	 ELSE ending_headway END AS artificial_end_buffer
FROM gap_calculation;

SELECT * FROM buffers LIMIT 1000;


-- Take min values to merge the rows
-- We want a reference table of the artificial buffers we have at our disposal for every stop on every route in each direction for each time period
-- There should be a row in this table for each stop/route/direction/time period in the headways table: SELECT DISTINCT sdp_route_id, direction_id, master_stop_id, sdp_timeperiod_desc FROM headways;
DROP TABLE IF EXISTS buffer_ref;
CREATE TEMP TABLE buffer_ref AS
SELECT 
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,MIN(artificial_start_buffer) AS artificial_start_buffer
	,MIN(artificial_end_buffer) AS artificial_end_buffer
FROM buffers
GROUP BY
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
ORDER BY sdp_route_id, sdp_timeperiod_desc, direction_id, master_stop_id;

SELECT * FROM buffer_ref LIMIT 100;


--------------------------------------
-- Let's calculate the expected wait time at a stop using the raw headways while considering all gaps (good and bad)
-- This will be used for stops that fail when calculating expected wait time from raw headways alone
-- If a stop fails, you want to account for any large gaps but also give some credit for smaller ones
DROP TABLE IF EXISTS buffer_headways_all;
CREATE TEMP TABLE buffer_headways_all AS
SELECT -- get all the headways that came from raw service
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,headway_minutes
FROM headways
WHERE headway_minutes IS NOT NULL
UNION ALL
SELECT -- union in all the artificial headways based on the starting gap
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,artificial_start_buffer AS headway_minutes
FROM buffer_ref
UNION ALL
SELECT -- union in all the artificial headways based on the ending gap
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,artificial_end_buffer AS headway_minutes
FROM buffer_ref;

SELECT * FROM buffer_headways_all LIMIT 1000;


-- Now calculate the expected wait time including these buffer values
DROP TABLE IF EXISTS headway_calculations_experimental_all;
CREATE TEMP TABLE headway_calculations_experimental_all AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
    ,MAX(headway_minutes) AS max_headway
    ,SUM(headway_minutes^2) / SUM(headway_minutes) AS avg_expected_wait_time
FROM buffer_headways_all
GROUP BY
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark;
	
SELECT * FROM headway_calculations_experimental_all LIMIT 1000;


--------------------------------------
-- Now let's create another experimental set, only including BAD gaps (those over the benchmark)
-- This will come into play when a stop passes, and we just want to check if the bad gap is enough to through it over the edge
DROP TABLE IF EXISTS buffer_headways_poor;
CREATE TEMP TABLE buffer_headways_poor AS
SELECT -- get all the headways that came from raw service
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,headway_minutes
FROM headways
WHERE headway_minutes IS NOT NULL
UNION ALL
SELECT -- union in the artificial headways based on the starting gap, IF this value exceeds the benchmark
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,artificial_start_buffer AS headway_minutes
FROM buffer_ref
WHERE artificial_start_buffer > benchmark
UNION ALL
SELECT -- union in the artificial headways based on the ending gap, IF this value exceeds the benchmark
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,artificial_end_buffer AS headway_minutes
FROM buffer_ref
WHERE artificial_end_buffer > benchmark;

SELECT * FROM buffer_headways_poor LIMIT 1000;


-- Now calculate the headways including these restricted buffer values
DROP TABLE IF EXISTS headway_calculations_experimental_poor;
CREATE TEMP TABLE headway_calculations_experimental_poor AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
    ,MAX(headway_minutes) AS max_headway
    ,SUM(headway_minutes^2) / SUM(headway_minutes) AS avg_expected_wait_time
FROM buffer_headways_poor
GROUP BY
	 sdp_route_id
	,sdp_route_desc
	,direction_id
	,master_stop_id
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark;
	
SELECT * FROM headway_calculations_experimental_poor LIMIT 1000;



------------------------------------------------------------
-- Now we calculate the headways using only real headways
DROP TABLE IF EXISTS headway_calculations_main;
CREATE TEMP TABLE headway_calculations_main AS
SELECT
    sdp_route_id
   ,sdp_route_desc
   ,rpt_timeperiod_id
   ,sdp_timeperiod_desc
   ,direction_id
   ,master_stop_id
   ,benchmark
   ,MAX(headway_minutes) AS max_headway
   ,SUM(headway_minutes^2) / SUM(headway_minutes) AS avg_expected_wait_time
FROM headways
GROUP BY 
    sdp_route_id
   ,sdp_route_desc
   ,rpt_timeperiod_id
   ,sdp_timeperiod_desc
   ,direction_id
   ,master_stop_id
   ,benchmark
ORDER BY sdp_route_id, rpt_timeperiod_id, sdp_timeperiod_desc, direction_id, master_stop_id;

SELECT * FROM headway_calculations_main;

-- Note that time periods with only a single stop event are in this table, but their value is null
SELECT * FROM headway_calculations_main WHERE max_headway IS NULL;


------------------------------------------------------------
-- We just calculated the expected wait time three separate ways
-- The "main" calculation will tell us how a stop performs using raw headways alone
-- The "all" calculation will be used when the stop fails on its own, to check if the gaps could help it to pass
-- The "poor" calculation will be used when the stop passes on its own, to check if it is still able to do so considering any bad gaps

-- The table below provides the score each stop receives using each of these methods
-- The query will select between using the "all (gaps)" option or the "poor (gaps)" option, depending on the "raw" score
DROP TABLE IF EXISTS options;
CREATE TEMP TABLE options AS
SELECT
	 m.sdp_route_id
    ,m.sdp_route_desc
	,m.rpt_timeperiod_id
	,m.sdp_timeperiod_desc
	,m.direction_id
    ,m.master_stop_id
    ,m.benchmark
	-- Raw results using just the "real" headways
    ,m.max_headway AS max_headway_raw
    ,m.avg_expected_wait_time AS expected_wait_raw
	,CASE
	 WHEN m.avg_expected_wait_time > m.benchmark THEN 'FAIL'
	 WHEN m.avg_expected_wait_time IS NULL THEN 'FAIL'
	 ELSE 'PASS' END AS score_raw
	-- Results considering the raw headways and all gaps, good or bad
    ,e.max_headway AS max_headway_all
    ,e.avg_expected_wait_time AS expected_wait_all
	,CASE
	 WHEN e.avg_expected_wait_time > m.benchmark THEN 'FAIL'
	 ELSE 'PASS' END AS score_all
	-- Results considering the raw headways and bad gaps only
    ,p.max_headway AS max_headway_poor
    ,p.avg_expected_wait_time AS expected_wait_poor
	,CASE
	 WHEN p.avg_expected_wait_time > m.benchmark THEN 'FAIL'
	 ELSE 'PASS' END AS score_poor
FROM headway_calculations_main m
-- You should always have the same number of records in all three of these tables, so you can use any join you like
FULL OUTER JOIN headway_calculations_experimental_all e
	ON m.sdp_route_id = e.sdp_route_id
	AND m.rpt_timeperiod_id = e.rpt_timeperiod_id
	AND m.direction_id = e.direction_id
	AND m.master_stop_id = e.master_stop_id
FULL OUTER JOIN headway_calculations_experimental_poor p
	ON m.sdp_route_id = p.sdp_route_id
	AND m.rpt_timeperiod_id = p.rpt_timeperiod_id
	AND m.direction_id = p.direction_id
	AND m.master_stop_id = p.master_stop_id;
	
-- Notice the join is complete.
SELECT * FROM options WHERE sdp_route_id IS NULL;


-- Now we need to take these options and select which treatment we want to apply, based on how the stop performs given its raw headways
-- If the stop passes on its own, then just check that poor gaps don't throw it off
-- If the stop fails on its own, then check all gaps, giving credit for decent ones and penalizing further for bad ones
DROP TABLE IF EXISTS stop_treatment;
CREATE TEMP TABLE stop_treatment AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,direction_id
	,master_stop_id
	,benchmark
--	,max_headway_raw
--	,expected_wait_raw
--	,score_raw
	,CASE
	 WHEN score_raw = 'PASS' THEN max_headway_poor
	 WHEN score_raw = 'FAIL' THEN max_headway_all
	 END AS max_headway_adjusted
	,CASE
	 WHEN score_raw = 'PASS' THEN expected_wait_poor
	 WHEN score_raw = 'FAIL' THEN expected_wait_all
	 END AS expected_wait_adjusted
	,CASE
	 WHEN score_raw = 'PASS' THEN score_poor
	 WHEN score_raw = 'FAIL' THEN score_all
	 END AS score_adjusted
FROM options;

SELECT * FROM stop_treatment;


------------------------------------------------------------
-- Let's put the results of the stop-level frequencies in context by providing the percent of service alongside them
DROP TABLE IF EXISTS results_context;
CREATE TEMP TABLE results_context AS
SELECT
    r.*
   ,p.stop_percent_to_max
FROM stop_treatment r
JOIN percent_to_max p ON r.sdp_route_id = p.sdp_route_id AND r.master_stop_id = p.master_stop_id AND r.direction_id = p.direction_id AND r.sdp_timeperiod_desc = p.sdp_timeperiod_desc;

SELECT * FROM results_context ORDER BY sdp_route_id, sdp_timeperiod_desc, direction_id;

-- Our typicality classification is not yet complete
-- Not only do we want to consider each stop's percent to max
-- We also want to consider if the gaps at the beginning/end of service make it atypical

-- Let's look back at the gap_calculation table and find the raw gap between the first/last service and the time period boundaries
DROP TABLE IF EXISTS gap_ref;
CREATE TEMP TABLE gap_ref AS
SELECT 
	 master_stop_id
	,sdp_route_id
	,direction_id
	,sdp_timeperiod_desc
	,timeperiod_start
	,timeperiod_end
	,timeperiod_end - timeperiod_start AS timeperiod_duration
	,MAX(starting_headway) AS starting_headway
	,MAX(ending_headway) AS ending_headway
FROM gap_calculation
GROUP BY
	 master_stop_id
	,sdp_route_id
	,direction_id
	,sdp_timeperiod_desc
	,timeperiod_start
	,timeperiod_end
	,timeperiod_end - timeperiod_start;
	
SELECT * FROM gap_ref;


-- Let's add some additional context to the results and the percent to max
DROP TABLE IF EXISTS results_context_gap;
CREATE TEMP TABLE results_context_gap AS
SELECT 
	 r.*
	,(EXTRACT(hour FROM g.timeperiod_duration) * 60) + EXTRACT(minute FROM g.timeperiod_duration) AS timeperiod_duration
	,g.starting_headway
	,g.ending_headway
FROM results_context r
LEFT JOIN gap_ref g
	ON r.master_stop_id = g.master_stop_id
	AND r.sdp_route_id = g.sdp_route_id
	AND r.direction_id = g.direction_id
	AND r.sdp_timeperiod_desc = g.sdp_timeperiod_desc;
	
-- Preview
SELECT * FROM results_context_gap LIMIT 10;


-- Explanation:
-- We will be incorporating a gap check into the typicality definition here
-- First, we need to check where a gap check is even relevant when you consider the length of the period and the target headway
-- Some benchmarks are too long and some time periods are too short
-- Using the Twenty Twenty-One time periods and headway standards:
---- We can only fit 2.5 local bus trips into Midday School (skipping 2 is almost the entire period and would leave you without service)
---- We can only fit 4 KBR/RT trips into Early AM
---- We can only fit 4 Local Bus trips into AM Peak (skipping 2 is 1/2 the period, whereas on KBR skipping 2 is 1/6 of the period)
-- Let's set the cutoff at 4 trips per period.  If skipping two trips would result in missing more than half the headway, we won't evaluate typicality based on gap and will instead count gaps as a headway
-- For routes where you can skip two trips and not already take up half of the period, we will check that not 50% or more of the period is comprised of gaps
-- Note that we add 1 minute to the time period durations to make them even increments (as headways/trips per hour are based on time periods that are to the nearest half hour)
SELECT DISTINCT 
	 sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,benchmark
	,timeperiod_duration + 1 AS timeperiod_duration
	,(timeperiod_duration + 1) / benchmark AS trips
FROM results_context_gap
ORDER BY sdp_route_desc, rpt_timeperiod_id;


-- Calculation:
-- If you can fit fewer than 4 trips into the period given the target headway (meaning skipping two trips would cause you to miss half the period)
-- Then we will not evaluate your gaps to determine the typicality of a stop.  They will be applied as headways where applicable
-- Let's see which periods will not receive this extra layer of typicality scrutiny
DROP TABLE IF EXISTS gap_eligible_check;
CREATE TEMP TABLE gap_eligible_check AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,direction_id
	,master_stop_id
	,benchmark
	,max_headway_adjusted
	,expected_wait_adjusted
	,stop_percent_to_max
	,timeperiod_duration
	,starting_headway
	,ending_headway
	,CASE
	 WHEN (timeperiod_duration + 1) / benchmark < 4 THEN 0 -- If the period is short relative to the benchmark, do not check for gap typicality
	 ELSE 1 -- Otherwise the period must have been long enough, and you should check for gap typicality
	 END AS gap_eligible
FROM results_context_gap;

-- Notice that local bus during midday school will no longer be considered eligible for the gap check
SELECT DISTINCT sdp_route_desc, sdp_timeperiod_desc, gap_eligible FROM gap_eligible_check;


-- Assign stop typicality
-- For ALL time periods/route types, check that the stop receives at least 25% of service compared to the most-served stop
-- If you are a service in a time period where you can fit at least 4 trips, then also evaluate that the gaps are not more than 50% of the period
DROP TABLE IF EXISTS typical_flag;
CREATE TEMP TABLE typical_flag AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,direction_id
	,master_stop_id
	,benchmark
	,max_headway_adjusted
	,expected_wait_adjusted
	,stop_percent_to_max
	,timeperiod_duration
	,starting_headway
	,ending_headway
	,gap_eligible
	-- Check the percent to max for all stops
	,CASE 
	 WHEN stop_percent_to_max < .25 THEN 'LESS THAN 25%'
	 ELSE 'OK' END AS threshold
	-- Check the gap allowance where applicable
	,CASE WHEN gap_eligible = 1 AND (starting_headway + ending_headway)::DOUBLE PRECISION / timeperiod_duration >= .5 THEN 'BAD GAP'
	 ELSE 'OK' END AS gap_check
	-- Assign the overall typicality classification
	,CASE
	 WHEN stop_percent_to_max < .25 THEN 0 -- If percent to max is under 25%, it is automatically atypical
	 WHEN gap_eligible = 1 AND (starting_headway + ending_headway)::DOUBLE PRECISION / timeperiod_duration >= .5 THEN 0 -- Where applicable, gaps of at least half the period signal atypicality
	 ELSE 1 END AS is_typical -- Else the stop is typical
FROM gap_eligible_check;

-- Preview
SELECT * FROM typical_flag;


-- For reference, this query will show you the difference between groups (time periods, route types, and stop typicality classifications)
-- The averages between these groups should be distinct
SELECT
	 sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,timeperiod_duration
	,benchmark
	,is_typical
	,AVG(stop_percent_to_max) AS avg_stop_pct_to_max
	,AVG((starting_headway + ending_headway) / timeperiod_duration) AS avg_gap_ratio
	,AVG((starting_headway + ending_headway)) AS avg_gap_length
FROM typical_flag
GROUP BY sdp_route_desc, rpt_timeperiod_id, sdp_timeperiod_desc, benchmark, timeperiod_duration, is_typical
ORDER BY rpt_timeperiod_id, sdp_route_desc, is_typical;


-- Now let's look at the route level: What is the ratio of timepoints that will be considered for each route?
DROP TABLE IF EXISTS timepoint_consideration_ratio;
CREATE TEMP TABLE timepoint_consideration_ratio AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,direction_id
	,SUM(CASE WHEN is_typical = 1 THEN 1 ELSE 0 END) AS typical_count
	,SUM(CASE WHEN is_typical = 0 THEN 1 ELSE 0 END) AS atypical_count
	,COUNT(*) AS stop_count
	,SUM(CASE WHEN is_typical = 1 THEN 1 ELSE 0 END)::DOUBLE PRECISION / (SUM(CASE WHEN is_typical = 1 THEN 1 ELSE 0 END) + SUM(CASE WHEN is_typical = 0 THEN 1 ELSE 0 END))::DOUBLE PRECISION AS total_stops_considered
FROM typical_flag
GROUP BY
	 sdp_route_id
	,sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,direction_id
ORDER BY sdp_route_id, direction_id, rpt_timeperiod_id;

SELECT * FROM timepoint_consideration_ratio ORDER BY total_stops_considered ASC;


------------------------------------------------------
-- We now have expected wait times calculated (and properly adjusted) at the stop level
-- We have also determined which of these stops are typical, and which ones are atypical and should not be considered in the route average
-- Now we will roll up to the route-level value
DROP TABLE IF EXISTS route_rollup;
CREATE TEMP TABLE route_rollup AS
SELECT
		 sdp_route_id
		,sdp_route_desc
		,rpt_timeperiod_id
		,sdp_timeperiod_desc
		,direction_id
		,benchmark
		,MAX(max_headway_adjusted) AS max_headway_adjusted
		,ROUND(AVG(expected_wait_adjusted)::NUMERIC, 0) AS mean_expected_wait_time_adjusted
FROM typical_flag
WHERE is_typical = 1
GROUP BY
		 sdp_route_id
		,sdp_route_desc
		,rpt_timeperiod_id
		,sdp_timeperiod_desc
		,direction_id
		,benchmark
ORDER BY sdp_route_id, rpt_timeperiod_id, direction_id;

SELECT * FROM route_rollup ORDER BY sdp_route_id, rpt_timeperiod_id, direction_id DESC;


-- Now mark whether the route/direction/time period passed or failed
DROP TABLE IF EXISTS route_scores;
CREATE TEMP TABLE route_scores AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,rpt_timeperiod_id
	,sdp_timeperiod_desc
	,direction_id
	,benchmark
	,max_headway_adjusted
	,mean_expected_wait_time_adjusted
	,CASE
	 WHEN mean_expected_wait_time_adjusted <= benchmark THEN 'PASS'
	 ELSE 'FAIL'
	 END AS freq_score_adjusted
FROM route_rollup;

SELECT *
FROM route_scores
ORDER BY sdp_route_id, rpt_timeperiod_id, direction_id;


-- Now we need to join the ratio of timepoints used to arrive at these scores
-- It is possible that no stops on the route were considered typical
-- They will therefore have been filtered out by the route_rollup calculation
-- In the timepoint ratio table, you will find these routes with a ratio of 0
-- The full outer join with coalesce allows you to add these into this table and automatically fail the routes
DROP TABLE IF EXISTS timepoint_ratio_join;
CREATE TEMP TABLE timepoint_ratio_join AS
SELECT 
	 COALESCE(rs.sdp_route_id, tcr.sdp_route_id) AS sdp_route_id
	,COALESCE(rs.sdp_route_desc, tcr.sdp_route_desc) AS sdp_route_desc
	,COALESCE(rs.rpt_timeperiod_id, tcr.rpt_timeperiod_id) AS rpt_timeperiod_id
	,COALESCE(rs.sdp_timeperiod_desc, tcr.sdp_timeperiod_desc) AS sdp_timeperiod_desc
	,COALESCE(rs.direction_id, tcr.direction_id) AS direction_id
	,rs.benchmark
	,rs.max_headway_adjusted
	,rs.mean_expected_wait_time_adjusted
	,CASE 
	 WHEN rs.freq_score_adjusted IS NOT NULL THEN rs.freq_score_adjusted
	 ELSE 'FAIL'
	 END AS freq_score_adjusted
	,tcr.typical_count
	,tcr.atypical_count
	,tcr.stop_count
	,tcr.total_stops_considered
FROM route_scores rs
FULL OUTER JOIN timepoint_consideration_ratio tcr 
	ON rs.sdp_route_id = tcr.sdp_route_id
	AND rs.direction_id = tcr.direction_id
	AND rs.sdp_timeperiod_desc = tcr.sdp_timeperiod_desc
ORDER BY sdp_route_id, direction_id, rpt_timeperiod_id;

-- This table will show you where there were very few, if any, typical stops along the route
SELECT * FROM timepoint_ratio_join ORDER BY total_stops_considered ASC;



-----------------------------------------
-- If only one trip was found in GTFS, then the route's headways would be all gap and would either show up as such or fail automatically (depending on the route type and time period)
-- We want to check, however, that there were no routes with zero trips in this rating
-- While in theory these should not have ridership data attached to them, we want to have record of these as failing
-- To do this, we create a table that takes all the routes logged in this version of the SDP and finds when they should have been running based on where there are targets logged
-- We create a record for each route, direction, and applicable time period
DROP TABLE IF EXISTS period_check;
CREATE TEMP TABLE period_check AS
SELECT 
	 r.sdp_route_id -- get all routes
	,rc.sdp_route_desc -- join their route type
	,0 AS direction_id -- assign direction 0
	,tp.rpt_timeperiod_id -- this is typically used as the join field for other tables 
	,fb.sdp_timeperiod_desc -- use the route type to get all associated benchmarks
FROM sdp.routes r
CROSS JOIN parameters p
LEFT JOIN sdp.route_categories rc 
	ON rc.sdp_version = p.sdp_version
	AND LOWER(rc.rating) = LOWER(p.rating) 
	AND r.route_category = rc.route_category
LEFT JOIN sdp.freq_benchmarks fb 
	ON fb.sdp_version = p.sdp_version
	AND fb.daytype = p.day_type
	AND fb.sdp_route_desc = rc.sdp_route_desc
LEFT JOIN sdp.timeperiod tp
	ON tp.sdp_version = p.sdp_version
	AND tp.daytype = p.day_type
	AND tp.sdp_mode = rc.sdp_mode
	AND tp.sdp_timeperiod_desc = fb.sdp_timeperiod_desc
WHERE r.sdp_version = p.sdp_version AND rc.sdp_route_desc IN ('Local Bus', 'Key Bus', 'Community Bus', 'Rapid Transit')
UNION ALL -- now do the same as above, but for direction 1; then union all
SELECT 
	 r.sdp_route_id
	,rc.sdp_route_desc
	,1 AS direction_id
	,tp.rpt_timeperiod_id
	,fb.sdp_timeperiod_desc
FROM sdp.routes r
CROSS JOIN parameters p
LEFT JOIN sdp.route_categories rc 
	ON rc.sdp_version = p.sdp_version
	AND LOWER(rc.rating) = LOWER(p.rating)
	AND r.route_category = rc.route_category
LEFT JOIN sdp.freq_benchmarks fb 
	ON fb.sdp_version = p.sdp_version
	AND fb.daytype = p.day_type
	AND fb.sdp_route_desc = rc.sdp_route_desc
LEFT JOIN sdp.timeperiod tp
	ON tp.sdp_version = p.sdp_version
	AND tp.daytype = p.day_type
	AND tp.sdp_mode = rc.sdp_mode
	AND tp.sdp_timeperiod_desc = fb.sdp_timeperiod_desc
WHERE r.sdp_version = p.sdp_version AND rc.sdp_route_desc IN ('Local Bus', 'Key Bus', 'Community Bus', 'Rapid Transit');

SELECT * FROM period_check ORDER BY sdp_route_id, direction_id, rpt_timeperiod_id;


-- Now we can use the period check table to ensure we have a score for every listed route/direction/time period dictated by the SDP
-- If no score is found, then we should automatically fail the route, as it did not appear in GTFS
-- There should end up being no ridership data for these instances (as the route was not operated)
DROP TABLE IF EXISTS full_scores;
CREATE TEMP TABLE full_scores AS
SELECT 
	 p.sdp_route_id
	,p.sdp_route_desc
	,p.rpt_timeperiod_id
	,p.sdp_timeperiod_desc
	,p.direction_id
	,r.benchmark
	,r.max_headway_adjusted
	,r.mean_expected_wait_time_adjusted
	,CASE
	 WHEN r.freq_score_adjusted IS NULL THEN 'NO SERVICE' -- If this route/direction/time period never showed up in GTFS, mark it
	 ELSE r.freq_score_adjusted END AS freq_score_adjusted -- Otherwise take the score we found for it
	,r.typical_count
	,r.atypical_count
	,r.stop_count
	,r.total_stops_considered AS pct_stops_typical
FROM period_check p
LEFT JOIN timepoint_ratio_join r 
	ON p.sdp_route_id = r.sdp_route_id
	AND p.direction_id = r.direction_id
	AND p.rpt_timeperiod_id = r.rpt_timeperiod_id;
	
-- You will see there are some routes here that you know are no longer in service, along with some that may need attention.
-- The 456 in Autumn Twenty-Nineteen is a good example of where these distinctions become important.
-- It has no headway for the peaks and FAILs, this is due to no stop being typical enough during these periods (gaps are too large)
-- But then during the AM Peak inbound in particular, there is NO SERVICE at all.  This tag helps us differentiate the root cause.
SELECT * FROM full_scores WHERE freq_score_adjusted = 'NO SERVICE';
SELECT * FROM full_scores WHERE sdp_route_id = '456';


------------------------------------- JOIN TO RIDERSHIP
DROP TABLE IF EXISTS ridership;
CREATE TEMP TABLE ridership AS
SELECT
	 rs.sdp_route_id
	,rs.sdp_route_desc
	,rs.rpt_timeperiod_id
	,rs.sdp_timeperiod_desc
	,rs.direction_id
	,rs.benchmark
	,rs.max_headway_adjusted
	,rs.mean_expected_wait_time_adjusted
	,rs.freq_score_adjusted
	,rs.typical_count
	,rs.atypical_count
	,rs.stop_count
	,rs.pct_stops_typical
	,SUM(r.ridership) AS ridership -- take the sum because some SDP route IDs have ridership split across multiple GTFS route IDs (e.g., 116/117)
FROM full_scores rs
CROSS JOIN parameters p
LEFT JOIN sdp.ridership r 
	ON r.sdp_version = p.sdp_version
	AND LOWER(r.rating) = LOWER(p.rating)
	AND LOWER(r.day_type) = LOWER(p.day_type)
	AND r.sdp_route_id = rs.sdp_route_id 
	AND r.rpt_timeperiod_id = rs.rpt_timeperiod_id 
	AND rs.direction_id = r.direction_id
GROUP BY
	 rs.sdp_route_id
	,rs.sdp_route_desc
	,rs.rpt_timeperiod_id
	,rs.sdp_timeperiod_desc
	,rs.direction_id
	,rs.benchmark
	,rs.max_headway_adjusted
	,rs.mean_expected_wait_time_adjusted
	,rs.freq_score_adjusted
	,rs.typical_count
	,rs.atypical_count
	,rs.stop_count
	,rs.pct_stops_typical;

-- Here are the routes where no ridership was found
-- For example, check that Mattapan passes, otherwise you will need to put an asterisk next to the rapid transit score
SELECT * FROM ridership WHERE ridership is null;


------------------------------------- JOIN TO EQUITY
SELECT * FROM sdp.equity LIMIT 10;

DROP TABLE IF EXISTS equity;
CREATE TEMP TABLE equity AS
SELECT
	 r.sdp_route_id
	,r.sdp_route_desc
	,r.rpt_timeperiod_id
	,r.sdp_timeperiod_desc
	,r.direction_id
	,r.benchmark
	,r.max_headway_adjusted
	,r.mean_expected_wait_time_adjusted
	,r.freq_score_adjusted
	,r.typical_count
	,r.atypical_count
	,r.stop_count
	,r.pct_stops_typical
	,r.ridership
	,e.minority_pct
	,e.yn_minority_route_vs_system
	,e.yn_minority_route_vs_mode
	,r.ridership * e.minority_pct AS minority_riders_partial
	,CASE
	 WHEN e.yn_minority_route_vs_system = true THEN r.ridership
	 ELSE 0 END AS minority_riders_full_system
	,CASE
	 WHEN e.yn_minority_route_vs_mode = true THEN r.ridership
	 ELSE 0 END AS minority_riders_full_mode
	,e.lowincome_pct
	,e.yn_lowincome_route_vs_system
	,e.yn_lowincome_route_vs_mode
	,r.ridership * e.lowincome_pct AS lowincome_riders_partial
	,CASE
	 WHEN e.yn_lowincome_route_vs_system = true THEN r.ridership
	 ELSE 0 END AS lowincome_riders_full_system
	,CASE
	 WHEN e.yn_lowincome_route_vs_mode = true THEN r.ridership
	 ELSE 0 END AS lowincome_riders_full_mode
FROM ridership r
CROSS JOIN parameters p
LEFT JOIN sdp.equity e 
	ON e.sdp_version = p.sdp_version 
	AND LOWER(e.rating) = LOWER(p.rating)
	AND LOWER(e.day_type) = LOWER(p.day_type)
	AND r.sdp_route_id = e.sdp_route_id;

-- Export here for detailed results on each route/direction/time period
SELECT * FROM equity;


--------------------------------------- AGGREGATE AND STORE RESULTS
-- Let's save a version of the summarized results in the SDP schema
DROP TABLE IF EXISTS freq_bus_rt_summary;
CREATE TABLE freq_bus_rt_summary AS
SELECT 
	 sdp_route_desc
	,freq_score_adjusted
	,ROUND(SUM(ridership)) AS total_riders_in_span
	,ROUND(SUM(minority_riders_full_system)) AS minority_system
	,ROUND(SUM(minority_riders_full_mode)) AS minority_mode
	,ROUND(SUM(minority_riders_partial)) AS minority_partial_allocation
	,ROUND(SUM(lowincome_riders_full_system)) AS lowincome_system
	,ROUND(SUM(lowincome_riders_full_mode)) AS lowincome_mode
	,ROUND(SUM(lowincome_riders_partial)) AS lowincome_partial_allocation
FROM equity
WHERE freq_score_adjusted != 'NO SERVICE' -- ignore where there was no service
GROUP BY sdp_route_desc, freq_score_adjusted
ORDER BY sdp_route_desc, freq_score_adjusted;

SELECT * FROM freq_bus_rt_summary;


--------------------------------------------------------
-- Now we will show a list of routes at the day level as a binary acceptable/unacceptable
-- Routes are logged as acceptable if 95% of their daily ridership occurs during passing time periods
-- This is a "soft pass" that excuses minor faults in service
-- It also excuses doughnut holes in service where a route is not run during an entire period/direction
DROP TABLE IF EXISTS daily_riders;
CREATE TEMP TABLE daily_riders AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,SUM(CASE WHEN freq_score_adjusted = 'PASS' THEN ridership
	 ELSE 0 END) AS passing_riders
	,SUM(CASE WHEN freq_score_adjusted = 'FAIL' THEN ridership
	 ELSE 0 END) AS failing_riders
	,SUM(ridership) AS total_riders
FROM ridership
GROUP BY
	 sdp_route_id
	,sdp_route_desc
ORDER BY sdp_route_id;

-- Note that at this level there will be some routes included that had no ridership
SELECT * FROM daily_riders WHERE total_riders IS NULL OR total_riders = 0;


-- Now we check which routes were acceptable or not at the daily level
DROP TABLE IF EXISTS daily_accept;
CREATE TEMP TABLE daily_accept AS
SELECT
	 sdp_route_id
	,sdp_route_desc
	,passing_riders
	,failing_riders
	,passing_riders / total_riders AS daily_pass_rate
	,CASE WHEN passing_riders / total_riders >= .95 THEN 'ACCEPTABLE'
	 ELSE 'UNACCEPTABLE' END AS daily_accept
FROM daily_riders
WHERE total_riders IS NOT NULL AND total_riders != 0;

SELECT * FROM daily_accept;



-----------------------------------------------------
-- Now that the script has finished running, we will save the intermediate and final results
-- When you set your parameters for the rating season, rating year, and day type using find and replace, these table names will also update

-- Frequency and typicality information at the stop level
DROP TABLE IF EXISTS sdp.freq_fall_2019_weekday_stops;
CREATE TABLE sdp.freq_fall_2019_weekday_stops AS 
SELECT * FROM typical_flag;

SELECT * FROM sdp.freq_fall_2019_weekday_stops;

-- Full detail on each route/direction/time period
DROP TABLE IF EXISTS sdp.freq_fall_2019_weekday_route_dir_tp;
CREATE TABLE sdp.freq_fall_2019_weekday_route_dir_tp AS
SELECT * FROM equity;

SELECT * FROM sdp.freq_fall_2019_weekday_route_dir_tp;

-- Rolled up view by SDP route description (for reporting)
DROP TABLE IF EXISTS sdp.freq_fall_2019_weekday_category_rollup;
CREATE TABLE sdp.freq_fall_2019_weekday_category_rollup AS
SELECT * FROM freq_bus_rt_summary;

SELECT * FROM sdp.freq_fall_2019_weekday_category_rollup;

-- Each route's status as acceptable/unacceptable based on a 95% passing threshold
DROP TABLE IF EXISTS sdp.freq_fall_2019_weekday_daily_soft_pass;
CREATE TABLE sdp.freq_fall_2019_weekday_daily_soft_pass AS
SELECT * FROM daily_accept;

SELECT * FROM sdp.freq_fall_2019_weekday_daily_soft_pass;