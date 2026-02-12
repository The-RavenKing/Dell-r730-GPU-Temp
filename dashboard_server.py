#!/usr/bin/env python3
"""
Dell R730 GPU Fan Control - Web Dashboard Server

This Flask application provides a web-based dashboard for monitoring
GPU temperatures, fan speeds, and historical statistics.

Port: 8080 (configurable)
Database: /var/lib/dell_gpu_fan_control/metrics.db
"""

from flask import Flask, render_template, jsonify
import sqlite3
import os
from datetime import datetime, timedelta

app = Flask(__name__)

# Configuration
DB_PATH = '/var/lib/dell_gpu_fan_control/metrics.db'
PORT = 8080
HOST = '0.0.0.0'  # Listen on all interfaces

def get_db_connection():
    """Create a database connection"""
    if not os.path.exists(DB_PATH):
        return None
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

@app.route('/')
def index():
    """Serve the main dashboard page"""
    return render_template('dashboard.html')

@app.route('/api/current')
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
        
        conn.close()
        return jsonify(data)
    
    except Exception as e:
        conn.close()
        return jsonify({'error': str(e)}), 500

@app.route('/api/realtime/<int:minutes>')
def api_realtime(minutes=60):
    """Get temperature data for the last N minutes (for real-time graphs)"""
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
        
        conn.close()
        return jsonify(data)
    
    except Exception as e:
        conn.close()
        return jsonify({'error': str(e)}), 500

@app.route('/api/historical/<string:period>')
def api_historical(period='24h'):
    """Get historical statistics (24h, 7d, 30d)"""
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database not found'}), 404
    
    try:
        cursor = conn.cursor()
        
        # Determine time range
        if period == '24h':
            hours = 24
        elif period == '7d':
            hours = 24 * 7
        elif period == '30d':
            hours = 24 * 30
        else:
            hours = 24
        
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
        
        conn.close()
        return jsonify(data)
    
    except Exception as e:
        conn.close()
        return jsonify({'error': str(e)}), 500

@app.route('/api/events/<int:limit>')
def api_events(limit=50):
    """Get recent fan speed change events"""
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
        
        conn.close()
        return jsonify({'events': events})
    
    except Exception as e:
        conn.close()
        return jsonify({'error': str(e)}), 500

@app.route('/api/statistics')
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
        
        conn.close()
        return jsonify({'statistics': stats})
    
    except Exception as e:
        conn.close()
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    print(f"Starting Dell R730 GPU Fan Control Dashboard")
    print(f"Dashboard will be available at: http://localhost:{PORT}")
    print(f"Database: {DB_PATH}")
    print(f"\nPress Ctrl+C to stop")
    
    app.run(host=HOST, port=PORT, debug=False)
