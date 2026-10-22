"""专用两 keyspace 目录：将公开接口与 system_schema、独立 Python Driver 逐项核对。"""
import argparse
import json
import os
from pathlib import Path
import uuid

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.policies import RoundRobinPolicy

from acceptance_common import ROOT, provenance, run, write_json

KEYSPACES = ['mooncql_schema_a', 'mooncql_schema_b']


def compare(snapshot, session, metadata, selected):
    assert {keyspace['name'] for keyspace in snapshot['keyspaces']} == set(selected)
    counts = {'keyspaces': 0, 'tables': 0, 'columns': 0, 'types': 0, 'fields': 0}
    for keyspace in snapshot['keyspaces']:
        name = keyspace['name']
        stored = session.execute('SELECT durable_writes,replication FROM system_schema.keyspaces WHERE keyspace_name=%s', (name,)).one()
        independent = metadata.keyspaces[name]
        assert keyspace['durable_writes'] == stored.durable_writes == independent.durable_writes
        assert keyspace['replication'] == stored.replication
        assert keyspace['replication']['class'].split('.')[-1] == type(independent.replication_strategy).__name__
        assert keyspace['replication']['replication_factor'] == str(independent.replication_strategy.replication_factor_info)
        counts['keyspaces'] += 1
        actual_tables = {table['name']: table for table in snapshot['tables'] if table['keyspace'] == name}
        assert set(actual_tables) == set(independent.tables) | set(independent.views)
        for table_name, table in actual_tables.items():
            definition = independent.tables.get(table_name) or independent.views[table_name]
            assert table.get('base_table') == getattr(definition, 'base_table_name', None)
            columns = {column['name']: column for column in table['columns']}
            raw = {row.column_name: row for row in session.execute(
                'SELECT column_name,type,kind,position,clustering_order FROM system_schema.columns WHERE keyspace_name=%s AND table_name=%s', (name, table_name))}
            assert set(columns) == set(raw) == set(definition.columns)
            assert [column['name'] for column in table['partition_key']] == [column.name for column in definition.partition_key]
            assert [column['name'] for column in table['clustering_key']] == [column.name for column in definition.clustering_key]
            for column_name, column in columns.items():
                stored_column = raw[column_name]
                independent_column = definition.columns[column_name]
                assert column['cql_type'] == stored_column.type == independent_column.cql_type
                assert column['kind'] == stored_column.kind
                assert column['position'] == stored_column.position
                assert column['clustering_order'] == stored_column.clustering_order
                assert (column['kind'] == 'static') == independent_column.is_static
                assert (column['clustering_order'] == 'desc') == independent_column.is_reversed
                counts['columns'] += 1
            counts['tables'] += 1
        actual_types = {typ['name']: typ for typ in snapshot['user_types'] if typ['keyspace'] == name}
        assert set(actual_types) == set(independent.user_types)
        for type_name, typ in actual_types.items():
            stored = session.execute('SELECT field_names,field_types FROM system_schema.types WHERE keyspace_name=%s AND type_name=%s', (name, type_name)).one()
            independent_type = independent.user_types[type_name]
            assert typ['fields'] == [list(pair) for pair in zip(stored.field_names, stored.field_types)]
            assert typ['fields'] == [list(pair) for pair in zip(independent_type.field_names, independent_type.field_types)]
            counts['types'] += 1
            counts['fields'] += len(typ['fields'])
    assert snapshot['schema_version'] == session.execute('SELECT schema_version FROM system.local').one().schema_version.hex
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    folder = (args.output or ROOT / '.artifacts' / ('schema-reference-' + uuid.uuid4().hex)).resolve()
    folder.mkdir(parents=True, exist_ok=False)
    report = {'passed': False, 'cases': []}
    auth = PlainTextAuthProvider(os.environ['CQL_USERNAME'], os.environ['CQL_PASSWORD']) if os.environ.get('CQL_USERNAME') else None
    cluster = Cluster([os.environ.get('CQL_HOST', '127.0.0.1')], port=int(os.environ.get('CQL_PORT', '9042')), protocol_version=5,
                      compression='lz4' if os.environ.get('CQL_COMPRESSION') == 'lz4' else False, auth_provider=auth,
                      execution_profiles={EXEC_PROFILE_DEFAULT: ExecutionProfile(load_balancing_policy=RoundRobinPolicy())})
    try:
        report['provenance'] = provenance(folder)
        session = cluster.connect()
        for name in KEYSPACES:
            session.execute(f'DROP KEYSPACE IF EXISTS {name}')
            session.execute(f"CREATE KEYSPACE {name} WITH replication={{'class':'SimpleStrategy','replication_factor':1}}")
        session.execute('CREATE TYPE mooncql_schema_a.address(street text,zip int)')
        session.execute('CREATE TYPE mooncql_schema_a.detail(address frozen<address>,pair frozen<tuple<text,int>>)')
        session.execute('CREATE TABLE mooncql_schema_a.events(tenant text,day int,id bigint,note text static,payload frozen<detail>,tags map<text,text>,PRIMARY KEY((tenant,day),id)) WITH CLUSTERING ORDER BY(id DESC)')
        session.execute('CREATE TABLE mooncql_schema_b.counters(id int PRIMARY KEY,n counter)')
        session.execute('CREATE TYPE mooncql_schema_b.example(x int)')
        for label, selected in [('filtered', KEYSPACES[:1]), ('both', KEYSPACES), ('changed', KEYSPACES[:1])]:
            if label == 'changed':
                session.execute('ALTER TYPE mooncql_schema_a.address ADD country text')
                session.execute('ALTER TABLE mooncql_schema_a.events ADD extra text')
            cluster.refresh_schema_metadata()
            path = folder / (label + '.json')
            environment = dict(os.environ, CQL_SCHEMA_KEYSPACES=','.join(selected), CQL_SCHEMA_REPORT=str(path))
            run(['moon', 'run', 'cmd/schema'], folder, label, env=environment)
            snapshot = json.loads(path.read_text(encoding='utf-8'))
            report['cases'].append({'label': label, 'counts': compare(snapshot, session, cluster.metadata, selected)})
        report['passed'] = True
    finally:
        cluster.shutdown()
        write_json(folder / 'result.json', report)
    print('PASS schema snapshot matches system_schema and independent driver before and after ALTER', flush=True)


if __name__ == '__main__':
    main()
