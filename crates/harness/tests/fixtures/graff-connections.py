#!/usr/bin/env python3
"""Credential-free ACP peer: records routing, never contacts a model."""
import json
import pathlib
import sys

root = pathlib.Path(__file__).parent
mode = (root / 'mode').read_text().strip()
current = 'p1' if mode in ['already-selected', 'current-signed-out'] else 'p2'
switched = False


def emit(value):
    print(json.dumps(value), flush=True)


def option(level):
    return {'id': 'effort', 'name': 'Thought level', 'category': 'thought_level',
            'type': 'select', 'currentValue': level,
            'options': [{'value': level, 'name': level.title()}]}


def switched_option():
    result = option('low')
    result['options'].append({'value': 'high', 'name': 'High'})
    return result


def update(sid, fields):
    emit({'method': 'session/update', 'params': {'sessionId': sid, 'update': fields}})


for line in sys.stdin:
    req = json.loads(line)
    if 'id' not in req:
        continue
    with (root / 'wire.jsonl').open('a') as log:
        log.write(json.dumps(req) + '\n')
    method = req['method']
    if method == 'initialize':
        result = {'protocolVersion': 1, 'agentCapabilities': {'loadSession': True}}
        if mode == 'revoked-command':
            result['availableCommands'] = [{'name': 'model', 'description': 'Select model'}]
    elif method == 'session/load':
        result = {'sessionId': 'fixture', 'configOptions': [option('high' if current == 'p1' else 'low')]}
        if mode == 'revoked-command':
            result['availableCommands'] = []
        elif mode not in ['unsupported', 'foreign-command', 'late-command']:
            result['availableCommands'] = [{'name': 'model', 'description': 'Select model'}]
        if mode in ['foreign-command', 'late-command']:
            emit({'id': req['id'], 'result': result})
            update('other' if mode == 'foreign-command' else 'fixture', {
                'sessionUpdate': 'available_commands_update',
                'availableCommands': [{'name': 'model', 'description': 'Select model'}]})
            continue
    elif method == 'graff/models':
        result = {'current': {'provider': current, 'model': 'shared'}, 'models': [
            {'provider': 'p1', 'name': 'missing' if mode == 'missing-model' else 'shared',
             'authenticated': mode not in ['signed-out', 'current-signed-out'] and not (mode == 'auth-lost' and switched), 'effortLevels': ['high']} ]}
        if mode == 'missing-current' and switched:
            result.pop('current')
    elif method == 'session/prompt':
        text = req['params']['prompt'][0]['text']
        if text.startswith('/model'):
            assert text == '/model p1 shared'
            assert req['params']['sessionId'] == 'fixture'
            if mode == 'rejected':
                emit({'id': req['id'], 'error': {'code': -32602, 'message': 'switch rejected'}})
                continue
            switched = True
            if mode != 'ignored':
                current = 'p1'
            update('fixture', {'sessionUpdate': 'config_option_update', 'configOptions': [switched_option()]})
            # A different session's later update must not replace our target's metadata.
            update('other', {'sessionUpdate': 'config_option_update', 'configOptions': [option('low')]})
            result = {'stopReason': 'cancelled' if mode == 'cancelled' else 'end_turn'}
        else:
            assert text == 'hello'
            assert current == 'p1', 'user prompt reached the wrong connection'
            result = {'stopReason': 'end_turn'}
    elif method == 'session/set_config_option':
        assert current == 'p1'
        assert req['params']['value'] == 'high'
        result = {'configOptions': [option('high')]}
    else:
        result = {}
    emit({'jsonrpc': '2.0', 'id': req['id'], 'result': result})
