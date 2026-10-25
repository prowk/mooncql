"""复制同一负载到旧版本时，仅转换等价的 Builder API 名称，不改参数和测量逻辑。"""
import re


def for_baseline(source, client_api):
    if 'pub(all) struct ConnectionBuilder {' in client_api:
        return source
    for before, after in [
        ('ConnectionBuilder', 'Config'), ('SessionBuilder', 'SessionConfig'),
        ('with_connection_builder', 'with_connection'),
        ('with_serial_connection_builder', 'with_serial_connection'),
        ('with_session_builder', 'with_session'), ('connect_builder', 'connect'),
    ]:
        source = re.sub(r'\b' + before + r'\b', after, source)
    return source
