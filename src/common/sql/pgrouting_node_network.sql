
/*****************************************************************************
* Author: Nicolas Ribot, 2013
******************************************************************************/


CREATE OR REPLACE FUNCTION pgr_nodeNetwork(intab text, n_pkey text, n_geom text,  outtab text, tol double precision) RETURNS text AS
$BODY$
DECLARE
	/*
	 * Author: Nicolas Ribot, 2013
	*/
	p_num int := 0;
	p_ret text := '';
BEGIN

    -- First creates temp table with intersection points
    drop table  if exists intergeom;
    EXECUTE 'create temp table intergeom as 
        select l1.' || quote_ident(n_pkey) || ' as l1id, 
               l2.' || quote_ident(n_pkey) || ' as l2id, 
               st_intersection(l1.' || quote_ident(n_geom) || ', l2.' || quote_ident(n_geom) || ') as geom 
        from ' || quote_ident(intab) || ' l1 
             join ' || quote_ident(intab) || ' l2 
             on (st_dwithin(l1.' || quote_ident(n_geom) || ', l2.' || quote_ident(n_geom) || ', ' || tol || '))
        where l1.' || quote_ident(n_pkey) || ' <> l2.' || quote_ident(n_pkey);

    -- must handle the case where lines intersects at a linestring...

    EXECUTE 'insert into intergeom (l1id, l2id, ' || quote_ident(n_geom) || ')
        select l1id, l2id, st_startpoint(' || quote_ident(n_geom) || ')
        from intergeom where geometryType(' || quote_ident(n_geom) || ') = ''LINESTRING'' ';

	GET DIAGNOSTICS p_num = ROW_COUNT;
	raise notice 'Num inserts: %', p_num;

    EXECUTE 'insert into intergeom (l1id, l2id, ' || quote_ident(n_geom) || ')
        select l1id, l2id, st_endpoint(' || quote_ident(n_geom) || ')
        from intergeom where geometryType(' || quote_ident(n_geom) || ') = ''LINESTRING'' ';

	GET DIAGNOSTICS p_num = ROW_COUNT;
	raise notice 'Num inserts: %', p_num;
	
    -- keeps only true intersection points
    EXECUTE 'delete from intergeom where geometryType(' || quote_ident(n_geom) || ') <> ''POINT'' ';

	GET DIAGNOSTICS p_num = ROW_COUNT;
	raise notice 'Num deleted: %', p_num;

    -- second temp table with locus (index of intersection point on the line)
    -- to avoid updating the previous table
    -- we keep only intersection points occuring onto the line, not at one of its ends
    drop table if exists inter_loc;
    EXECUTE 'create temp table inter_loc as (
        select l1id, l2id, st_line_locate_point(l.' || quote_ident(n_geom) || ', i.' || quote_ident(n_geom) || ') as locus
        from intergeom i left join ' || quote_ident(intab) || ' l on (l.' || quote_ident(n_pkey) || ' = i.l1id)
        where st_line_locate_point(l.' || quote_ident(n_geom) || ', i.' || quote_ident(n_geom) || ') <> 0 
              and st_line_locate_point(l.' || quote_ident(n_geom) || ', i.' || quote_ident(n_geom) || ') <> 1
        )';

    -- index on l1id
    create index inter_loc_id_idx on inter_loc(l1id);

    -- Then computes the intersection on the lines subset, which is much smaller than full set 
    -- as there are very few intersection points
   EXECUTE 'drop table if exists ' || quote_ident(outtab);
   EXECUTE 'create table ' || quote_ident(outtab) || ' as 
       with cut_locations as (
           select l1id as lid, locus 
           from inter_loc
           -- then generates start and end locus for each line that have to be cut buy a location point
           UNION ALL
           select i.l1id  as lid, 0 as locus
           from inter_loc i left join ' || quote_ident(intab) || ' b on (i.l1id = b.' || quote_ident(n_pkey) || ')
           UNION ALL
           select i.l1id  as lid, 1 as locus
           from inter_loc i left join ' || quote_ident(intab) || ' b on (i.l1id = b.' || quote_ident(n_pkey) || ')
           order by lid, locus
       ), 
       -- we generate a row_number index column for each input line 
       -- to be able to self-join the table to cut a line between two consecutive locations 
       loc_with_idx as (
           select lid, locus, row_number() over (partition by lid order by locus) as idx
           from cut_locations
       ) 
       -- finally, each original line is cut with consecutive locations using linear referencing functions
       select l.' || quote_ident(n_pkey) || ', loc1.idx as sub_id, st_line_substring(l.geom, loc1.locus, loc2.locus) as ' || quote_ident(n_geom) || ' 
       from loc_with_idx loc1 join loc_with_idx loc2 using (lid) join ' || quote_ident(intab) || ' l on (l.' || quote_ident(n_pkey) || ' = loc1.lid)
       where loc2.idx = loc1.idx+1
           -- keeps only linestring geometries
           and geometryType(st_line_substring(l.' || quote_ident(n_geom) || ', loc1.locus, loc2.locus)) = ''LINESTRING'' ';

	-- here, it misses all original line that did not need to be cut by intersection points: these lines
	-- are already clean
	-- inserts them in the final result: all lines which gid is not in the res table.
	EXECUTE 'insert into ' || quote_ident(outtab) || ' (' || quote_ident(n_pkey) || ', sub_id, ' || quote_ident(n_geom) || ')
		select ' || quote_ident(intab) || '.' || quote_ident(n_pkey) || ', 1 as sub_id, ' || quote_ident(intab) || '.geom
		from ' || quote_ident(intab) || '
		where not exists (
			select ' || quote_ident(outtab) || '.' || quote_ident(n_pkey) || ' from ' || quote_ident(outtab) || ' 
			where ' || quote_ident(outtab) || '.' || quote_ident(n_pkey) || ' = ' || quote_ident(intab) || '.' || quote_ident(n_pkey) || '
		)';

	GET DIAGNOSTICS p_num = ROW_COUNT;
	raise notice 'Num inserted: %', p_num;

	EXECUTE 'SELECT ' || quote_ident(n_pkey) || ' from ' || quote_ident(outtab) || '';
	GET DIAGNOSTICS p_num = ROW_COUNT;
	p_ret := '' || outtab || ' generated with: ' || p_num || ' segments';
	--p_ret := '' || outtab || ' generated';
    RETURN p_ret;
END;
$BODY$
    LANGUAGE 'plpgsql' VOLATILE STRICT COST 100;


