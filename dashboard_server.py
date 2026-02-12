#!/usr/bin/env python3
"""
Dell R730 GPU Fan Control - Web Dashboard Server

This Flask application provides a web-based dashboard for monitoring
GPU temperatures, fan speeds, and historical statistics.

Port: 8080 (configurable)
Database: /var/lib/dell_gpu_fan_control/metrics.db
"""

from flask import Flask, render_template, jsonify, request, redirect, url_for, session
import sqlite3
import os
import json
import threading
import time
import hashlib
import secrets
from datetime import datetime, timedelta
from functools import wraps

app = Flask(__name__)

# Paths
CONFIG_DIR = '/var/lib/dell_gpu_fan_control'
CONFIG_PATH = os.path.join(CONFIG_DIR, 'config.json')
DB_PATH = os.path.join(CONFIG_DIR, 'metrics.db')
PORT = 8080
HOST = '127.0.0.1'  # Localhost only — nginx handles external access

# Default configuration
DEFAULT_CONFIG = {
    'dashboard': {
        'username': 'admin',
        'password_hash': hashlib.sha256(b'changeme').hexdigest()
    },
    'idrac': {
        'host': '192.168.1.100',
        'username': 'root',
        'password': 'calvin'
    },
    'fan_control': {
        'temp_low': 40,
        'temp_normal': 50,
        'temp_warm': 60,
        'temp_hot': 70,
        'temp_critical': 80,
        'check_interval': 5,
        'rampdown_delay': 20
    }
}

def load_config():
    """Load configuration from JSON file, creating with defaults if missing"""
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, 'r') as f:
                config = json.load(f)
            # Merge with defaults to pick up any new keys added in updates
            for section in DEFAULT_CONFIG:
                if section not in config:
                    config[section] = DEFAULT_CONFIG[section]
                elif isinstance(DEFAULT_CONFIG[section], dict):
                    for key in DEFAULT_CONFIG[section]:
                        if key not in config[section]:
                            config[section][key] = DEFAULT_CONFIG[section][key]
            return config
        except (json.JSONDecodeError, IOError) as e:
            print(f"Error loading config: {e}. Using defaults.")
    return DEFAULT_CONFIG.copy()

def save_config(config):
    """Save configuration to JSON file"""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f, indent=2)

def get_config():
    """Get current config (cached in app context)"""
    if not hasattr(app, '_config') or app._config is None:
        app._config = load_config()
    return app._config

# Initialize config and Flask secret key
config = load_config()
save_config(config)  # Ensure file exists with merged defaults
app.secret_key = os.environ.get('FLASK_SECRET_KEY', secrets.token_hex(32))
app.permanent_session_lifetime = timedelta(hours=24)

def cleanup_database():
    """Prune old data to keep database size manageable"""
    conn = get_db_connection()
    if not conn:
        return
    
    try:
        print(f"Running database cleanup at {datetime.now()}...")
        # Delete detailed temperature readings older than 30 days
        cutoff_30d = int((datetime.now() - timedelta(days=30)).timestamp())
        cursor = conn.cursor()
        cursor.execute('DELETE FROM temperature_readings WHERE timestamp < ?', (cutoff_30d,))
        deleted_readings = cursor.rowcount
        
        # Delete fan events older than 90 days
        cutoff_90d = int((datetime.now() - timedelta(days=90)).timestamp())
        cursor.execute('DELETE FROM fan_events WHERE timestamp < ?', (cutoff_90d,))
        deleted_events = cursor.rowcount
        
        conn.commit()
        print(f"Cleanup complete: Deleted {deleted_readings} readings and {deleted_events} events.")
    except Exception as e:
        print(f"Error during database cleanup: {e}")
    finally:
        conn.close()

def background_cleanup_task():
    """Run cleanup periodically"""
    while True:
        try:
            cleanup_database()
        except Exception as e:
            print(f"Cleanup thread error: {e}")
        # Sleep for 24 hours
        time.sleep(86400)

def get_db_connection():
    """Create a database connection"""
    if not os.path.exists(DB_PATH):
        return None
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def login_required(f):
    """Decorator to require authentication for routes"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('authenticated'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

@app.route('/login', methods=['GET', 'POST'])
def login():
    """Handle login"""
    if request.method == 'POST':
        username = request.form.get('username', '')
        password = request.form.get('password', '')
        password_hash = hashlib.sha256(password.encode()).hexdigest()
        
        config = get_config()
        if username == config['dashboard']['username'] and password_hash == config['dashboard']['password_hash']:
            session.permanent = True
            session['authenticated'] = True
            return redirect(url_for('index'))
        else:
            return render_template('login.html', error='Invalid username or password')
    
    return render_template('login.html')

@app.route('/logout')
def logout():
    """Handle logout"""
    session.clear()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def index():
    """Serve the main dashboard page"""
    return render_template('dashboard.html')

@app.route('/api/current')
@login_required
def api_current():
    """Get current/latest temperature and fan readings"""
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database not found'}), 404
    
    try:
        cursor = conn.cursor()
        
        # Get latest reading
        cursor.execute('''
            SELECT timestamp, gpu_temp, hotspot_temp, memory_temp, max_temp, fan_speed
            FROM temperature_readings
            ORDER BY timestamp DESC
            LIMIT 1
        ''')
        
        row = cursor.fetchone()
        if not row:
            return jsonify({'error': 'No data available'}), 404
        
        data = {
            'timestamp': row['timestamp'],
            'datetime': datetime.fromtimestamp(row['timestamp']).strftime('%Y-%m-%d %H:%M:%S'),
            'gpu_temp': row['gpu_temp'],
            'hotspot_temp': row['hotspot_temp'],
            'memory_temp': row['memory_temp'],
            'max_temp': row['max_temp'],
            'fan_speed': row['fan_speed']
        }
        
        return jsonify(data)
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        conn.close()

@app.route('/api/realtime/<int:minutes>')
@login_required
def api_realtime(minutes=60):
    """Get temperature data for the last N minutes (for real-time graphs)"""
    minutes = min(max(minutes, 1), 1440)  # Clamp to 1-1440 minutes (max 24h)
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database not found'}), 404
    
    try:
        cursor = conn.cursor()
        cutoff_time = int((datetime.now() - timedelta(minutes=minutes)).timestamp())
        
        cursor.execute('''
            SELECT timestamp, gpu_temp, hotspot_temp, memory_temp, max_temp, fan_speed
            FROM temperature_readings
            WHERE timestamp > ?
            ORDER BY timestamp ASC
        ''', (cutoff_time,))
        
        rows = cursor.fetchall()
        
        data = {
            'timestamps': [row['timestamp'] for row in rows],
            'gpu_temps': [row['gpu_temp'] for row in rows],
            'hotspot_temps': [row['hotspot_temp'] for row in rows],
            'memory_temps': [row['memory_temp'] for row in rows],
            'max_temps': [row['max_temp'] for row in rows],
            'fan_speeds': [row['fan_speed'] for row in rows]
        }
        
        return jsonify(data)
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        conn.close()

@app.route('/api/historical/<string:period>')
@login_required
def api_historical(period='24h'):
    """Get historical statistics (24h, 7d, 30d)"""
    # Validate period parameter
    valid_periods = {'24h': 24, '7d': 24 * 7, '30d': 24 * 30}
    if period not in valid_periods:
        return jsonify({'error': f'Invalid period: {period}. Valid: 24h, 7d, 30d'}), 400
    
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database not found'}), 404
    
    try:
        cursor = conn.cursor()
        
        # Determine time range
        hours = valid_periods[period]
        
        cutoff_time = int((datetime.now() - timedelta(hours=hours)).timestamp())
        
        # Get aggregated statistics
        cursor.execute('''
            SELECT 
                MIN(gpu_temp) as min_gpu,
                MAX(gpu_temp) as max_gpu,
                AVG(gpu_temp) as avg_gpu,
                MAX(hotspot_temp) as max_hotspot,
                MAX(memory_temp) as max_memory,
                MAX(fan_speed) as max_fan
            FROM temperature_readings
            WHERE timestamp > ?
        ''', (cutoff_time,))
        
        stats_row = cursor.fetchone()
        
        # Get hourly averages for graphing
        cursor.execute('''
            SELECT 
                (timestamp / 3600) * 3600 as hour_timestamp,
                AVG(gpu_temp) as avg_gpu,
                AVG(hotspot_temp) as avg_hotspot,
                AVG(memory_temp) as avg_memory,
                AVG(fan_speed) as avg_fan,
                MAX(max_temp) as peak_temp
            FROM temperature_readings
            WHERE timestamp > ?
            GROUP BY hour_timestamp
            ORDER BY hour_timestamp ASC
        ''', (cutoff_time,))
        
        hourly_rows = cursor.fetchall()
        
        data = {
            'period': period,
            'summary': {
                'min_gpu': round(stats_row['min_gpu'], 1) if stats_row['min_gpu'] else 0,
                'max_gpu': round(stats_row['max_gpu'], 1) if stats_row['max_gpu'] else 0,
                'avg_gpu': round(stats_row['avg_gpu'], 1) if stats_row['avg_gpu'] else 0,
                'max_hotspot': round(stats_row['max_hotspot'], 1) if stats_row['max_hotspot'] else 0,
                'max_memory': round(stats_row['max_memory'], 1) if stats_row['max_memory'] else 0,
                'max_fan': round(stats_row['max_fan'], 1) if stats_row['max_fan'] else 0
            },
            'hourly': {
                'timestamps': [row['hour_timestamp'] for row in hourly_rows],
                'avg_gpu': [round(row['avg_gpu'], 1) for row in hourly_rows],
                'avg_hotspot': [round(row['avg_hotspot'], 1) for row in hourly_rows],
                'avg_memory': [round(row['avg_memory'], 1) for row in hourly_rows],
                'avg_fan': [round(row['avg_fan'], 1) for row in hourly_rows],
                'peak_temp': [round(row['peak_temp'], 1) for row in hourly_rows]
            }
        }
        
        return jsonify(data)
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        conn.close()

@app.route('/api/events/<int:limit>')
@login_required
def api_events(limit=50):
    """Get recent fan speed change events"""
    limit = min(max(limit, 1), 500)  # Clamp to 1-500
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database not found'}), 404
    
    try:
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT timestamp, event_type, temperature, fan_speed, details
            FROM fan_events
            ORDER BY timestamp DESC
            LIMIT ?
        ''', (limit,))
        
        rows = cursor.fetchall()
        
        events = []
        for row in rows:
            events.append({
                'timestamp': row['timestamp'],
                'datetime': datetime.fromtimestamp(row['timestamp']).strftime('%Y-%m-%d %H:%M:%S'),
                'event_type': row['event_type'],
                'temperature': row['temperature'],
                'fan_speed': row['fan_speed'],
                'details': row['details']
            })
        
        return jsonify({'events': events})
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        conn.close()

@app.route('/api/statistics')
@login_required
def api_statistics():
    """Get latest hourly statistics summary"""
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database not found'}), 404
    
    try:
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT *
            FROM statistics
            ORDER BY period_end DESC
            LIMIT 10
        ''')
        
        rows = cursor.fetchall()
        
        stats = []
        for row in rows:
            stats.append({
                'period_start': datetime.fromtimestamp(row['period_start']).strftime('%Y-%m-%d %H:%M'),
                'period_end': datetime.fromtimestamp(row['period_end']).strftime('%Y-%m-%d %H:%M'),
                'peak_gpu_temp': row['peak_gpu_temp'],
                'peak_hotspot_temp': row['peak_hotspot_temp'],
                'peak_memory_temp': row['peak_memory_temp'],
                'avg_gpu_temp': row['avg_gpu_temp'],
                'max_fan_events': row['max_fan_events'],
                'high_temp_warnings': row['high_temp_warnings']
            })
        
        return jsonify({'statistics': stats})
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        conn.close()

@app.route('/settings')
@login_required
def settings():
    """Serve the settings page"""
    config = get_config()
    return render_template('settings.html', config=config)

@app.route('/api/settings/credentials', methods=['POST'])
@login_required
def update_credentials():
    """Update dashboard login credentials"""
    try:
        data = request.get_json()
        config = get_config()
        
        # Verify current password
        current_hash = hashlib.sha256(data.get('current_password', '').encode()).hexdigest()
        if current_hash != config['dashboard']['password_hash']:
            return jsonify({'error': 'Current password is incorrect'}), 403
        
        # Update username if provided
        new_username = data.get('new_username', '').strip()
        if new_username:
            config['dashboard']['username'] = new_username
        
        # Update password if provided
        new_password = data.get('new_password', '').strip()
        if new_password:
            if len(new_password) < 6:
                return jsonify({'error': 'Password must be at least 6 characters'}), 400
            config['dashboard']['password_hash'] = hashlib.sha256(new_password.encode()).hexdigest()
        
        save_config(config)
        app._config = config
        return jsonify({'success': True, 'message': 'Credentials updated successfully'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/settings/idrac', methods=['POST'])
@login_required
def update_idrac():
    """Update iDRAC connection settings"""
    try:
        data = request.get_json()
        config = get_config()
        
        host = data.get('host', '').strip()
        username = data.get('username', '').strip()
        password = data.get('password', '').strip()
        
        if not host:
            return jsonify({'error': 'iDRAC host/IP is required'}), 400
        if not username:
            return jsonify({'error': 'iDRAC username is required'}), 400
        if not password:
            return jsonify({'error': 'iDRAC password is required'}), 400
        
        config['idrac']['host'] = host
        config['idrac']['username'] = username
        config['idrac']['password'] = password
        
        save_config(config)
        app._config = config
        return jsonify({'success': True, 'message': 'iDRAC settings updated. Restart fan control service to apply.'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/settings/fan', methods=['POST'])
@login_required
def update_fan_settings():
    """Update fan control thresholds"""
    try:
        data = request.get_json()
        config = get_config()
        
        # Validate and update temperature thresholds
        fields = {
            'temp_low': (20, 50, 'Low temp threshold'),
            'temp_normal': (30, 60, 'Normal temp threshold'),
            'temp_warm': (40, 75, 'Warm temp threshold'),
            'temp_hot': (50, 85, 'Hot temp threshold'),
            'temp_critical': (60, 95, 'Critical temp threshold'),
            'check_interval': (2, 60, 'Check interval'),
            'rampdown_delay': (5, 120, 'Rampdown delay')
        }
        
        for field, (min_val, max_val, label) in fields.items():
            if field in data:
                try:
                    value = int(data[field])
                except (ValueError, TypeError):
                    return jsonify({'error': f'{label} must be a number'}), 400
                if value < min_val or value > max_val:
                    return jsonify({'error': f'{label} must be between {min_val} and {max_val}'}), 400
                config['fan_control'][field] = value
        
        # Validate temp ordering: low < normal < warm < hot < critical
        fc = config['fan_control']
        if not (fc['temp_low'] < fc['temp_normal'] < fc['temp_warm'] < fc['temp_hot'] < fc['temp_critical']):
            return jsonify({'error': 'Temperature thresholds must be in ascending order: low < normal < warm < hot < critical'}), 400
        
        save_config(config)
        app._config = config
        return jsonify({'success': True, 'message': 'Fan control settings updated. Restart fan control service to apply.'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    print(f"Starting Dell R730 GPU Fan Control Dashboard")
    print(f"Dashboard will be available at: http://localhost:{PORT}")
    print(f"Database: {DB_PATH}")
    
    # Start background cleanup thread
    cleanup_thread = threading.Thread(target=background_cleanup_task, daemon=True)
    cleanup_thread.start()
    print(f"Background cleanup task started")
    
    print(f"\nPress Ctrl+C to stop")
    
    app.run(host=HOST, port=PORT, debug=False)
