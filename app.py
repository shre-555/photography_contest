# app.py - Complete Flask Application with Environment Variables
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
import mysql.connector
from mysql.connector import Error
import os
from datetime import datetime
from functools import wraps
from config import Config

app = Flask(__name__)
app.config.from_object(Config)
app.secret_key = Config.SECRET_KEY

# Setup upload folder
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

# Get allowed extensions from config
ALLOWED_EXTENSIONS = Config.ALLOWED_EXTENSIONS

# ============================================
# DATABASE CONNECTION HELPER
# ============================================
def get_db_connection():
    """Create and return a database connection"""
    try:
        connection = mysql.connector.connect(**Config.get_db_config())
        return connection
    except Error as e:
        print(f"Error connecting to MySQL: {e}")
        return None

def execute_query(query, params=None, fetch_one=False, fetch_all=True, commit=False):
    """Execute a query and return results"""
    connection = get_db_connection()
    if not connection:
        return None
    
    try:
        cursor = connection.cursor(dictionary=True)
        cursor.execute(query, params or ())
        
        if commit:
            connection.commit()
            return cursor.lastrowid
        elif fetch_one:
            return cursor.fetchone()
        elif fetch_all:
            return cursor.fetchall()
        
    except Error as e:
        print(f"Database error: {e}")
        if commit:
            connection.rollback()
        return None
    finally:
        cursor.close()
        connection.close()

def call_procedure(proc_name, params=None):
    """Call a stored procedure"""
    connection = get_db_connection()
    if not connection:
        return None
    
    try:
        cursor = connection.cursor(dictionary=True)
        cursor.callproc(proc_name, params or ())
        
        # Fetch results if any
        results = []
        for result in cursor.stored_results():
            results.extend(result.fetchall())
        
        connection.commit()
        return results
    except Error as e:
        print(f"Procedure error: {e}")
        connection.rollback()
        return None
    finally:
        cursor.close()
        connection.close()

# ============================================
# AUTHENTICATION DECORATORS
# ============================================
def login_required(f):
    """Decorator to require login"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'user_id' not in session:
            flash('Please login to access this page', 'warning')
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

def admin_required(f):
    """Decorator to require admin privileges"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'admin_id' not in session:
            flash('Admin access required', 'danger')
            return redirect(url_for('admin_login'))
        return f(*args, **kwargs)
    return decorated_function

# ============================================
# FILE UPLOAD HELPER
# ============================================
def allowed_file(filename):
    """Check if file extension is allowed"""
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# ============================================
# HOME & AUTH ROUTES
# ============================================
@app.route('/')
def index():
    """Home page with active contests"""
    # Update contest statuses first
    try:
        connection = get_db_connection()
        cursor = connection.cursor()
        cursor.execute("""
            UPDATE Contest
            SET Status = CASE
                WHEN NOW() < StartDate THEN 'Upcoming'
                WHEN NOW() BETWEEN StartDate AND EndDate THEN 'Active'
                WHEN NOW() > EndDate THEN 'Completed'
                ELSE Status
            END
            WHERE Status NOT IN ('Cancelled')
        """)
        connection.commit()
        cursor.close()
        connection.close()
    except:
        pass
    
    contests = execute_query("SELECT * FROM vw_active_contests ORDER BY EndDate ASC")
    return render_template('index.html', contests=contests)

@app.route('/register', methods=['GET', 'POST'])
def register():
    """User registration"""
    if request.method == 'POST':
        name = request.form.get('name')
        email = request.form.get('email')
        password = request.form.get('password')
        confirm_password = request.form.get('confirm_password')
        
        # Validation
        if not all([name, email, password, confirm_password]):
            flash('All fields are required', 'danger')
            return redirect(url_for('register'))
        
        if password != confirm_password:
            flash('Passwords do not match', 'danger')
            return redirect(url_for('register'))
        
        # Hash password
        hashed_password = generate_password_hash(password)
        
        # Check if email exists
        existing_user = execute_query(
            "SELECT * FROM User WHERE Email = %s",
            (email,),
            fetch_one=True
        )
        
        if existing_user:
            flash('Email already registered', 'danger')
            return redirect(url_for('register'))
        
        # Call stored procedure to register user
        result = call_procedure('sp_register_user', (name, email, hashed_password))
        
        if result:
            flash('Registration successful! Please login.', 'success')
            return redirect(url_for('login'))
        else:
            flash('Registration failed. Please try again.', 'danger')
    
    return render_template('register.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    """User login"""
    if request.method == 'POST':
        email = request.form.get('email')
        password = request.form.get('password')
        
        user = execute_query(
            "SELECT * FROM User WHERE Email = %s",
            (email,),
            fetch_one=True
        )
        
        if user and check_password_hash(user['Password'], password):
            session['user_id'] = user['UserID']
            session['user_name'] = user['Name']
            session['user_email'] = user['Email']
            flash(f'Welcome back, {user["Name"]}!', 'success')
            return redirect(url_for('dashboard'))
        else:
            flash('Invalid email or password', 'danger')
    
    return render_template('login.html')

@app.route('/logout')
def logout():
    """Logout user"""
    session.clear()
    flash('You have been logged out', 'info')
    return redirect(url_for('index'))

# ============================================
# USER DASHBOARD
# ============================================
@app.route('/dashboard')
@login_required
def dashboard():
    """User dashboard"""
    user_id = session['user_id']
    
    # Get user statistics
    stats = execute_query(
        "SELECT * FROM vw_user_dashboard WHERE UserID = %s",
        (user_id,),
        fetch_one=True
    )
    
    # Get user's photos
    photos = execute_query("""
        SELECT p.*, 
               GROUP_CONCAT(DISTINCT c.Title) AS Contests,
               COUNT(DISTINCT v.VoteID) AS TotalVotes
        FROM Photo p
        LEFT JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
        LEFT JOIN Contest c ON pcs.ContestID = c.ContestID
        LEFT JOIN Votes v ON p.PhotoID = v.PhotoID
        WHERE p.UserID = %s
        GROUP BY p.PhotoID
        ORDER BY p.UploadDate DESC
    """, (user_id,))
    
    # Get active contests
    active_contests = execute_query(
        "SELECT * FROM vw_active_contests ORDER BY EndDate ASC LIMIT 5"
    )
    
    return render_template('dashboard.html', stats=stats, photos=photos, 
                         active_contests=active_contests)

# ============================================
# CONTEST ROUTES
# ============================================
@app.route('/contests')
def contests():
    """List all contests"""
    all_contests = execute_query("""
        SELECT c.*, a.Name AS ManagerName,
               COUNT(DISTINCT pcs.PhotoID) AS TotalSubmissions,
               COUNT(DISTINCT v.VoteID) AS TotalVotes
        FROM Contest c
        LEFT JOIN Admin a ON c.Manager_id = a.AdminID
        LEFT JOIN PhotoContestSubmission pcs ON c.ContestID = pcs.ContestID
        LEFT JOIN Votes v ON c.ContestID = v.ContestID
        GROUP BY c.ContestID
        ORDER BY c.StartDate DESC
    """)
    return render_template('contests.html', contests=all_contests)

@app.route('/contest/<int:contest_id>')
def contest_detail(contest_id):
    """Contest details and leaderboard"""
    contest = execute_query(
        "SELECT * FROM Contest WHERE ContestID = %s",
        (contest_id,),
        fetch_one=True
    )
    
    if not contest:
        flash('Contest not found', 'danger')
        return redirect(url_for('contests'))
    
    # Get leaderboard with actual photo file paths
    leaderboard = execute_query("""
        SELECT 
            c.ContestID,
            c.Title AS ContestTitle,
            p.PhotoID,
            p.Title AS PhotoTitle,
            p.FilePath,
            u.Name AS PhotographerName,
            u.Email AS PhotographerEmail,
            u.UserID AS PhotographerID,
            COUNT(DISTINCT v.VoteID) AS TotalVotes,
            pcs.SubmissionTimestamp,
            pcs.SubmissionStatus,
            RANK() OVER (ORDER BY COUNT(DISTINCT v.VoteID) DESC) AS `Rank`
        FROM Contest c
        INNER JOIN PhotoContestSubmission pcs ON c.ContestID = pcs.ContestID
        INNER JOIN Photo p ON pcs.PhotoID = p.PhotoID
        INNER JOIN User u ON p.UserID = u.UserID
        LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = c.ContestID
        WHERE c.ContestID = %s
        GROUP BY c.ContestID, c.Title, p.PhotoID, p.Title, p.FilePath, 
                 u.Name, u.Email, u.UserID, pcs.SubmissionTimestamp, pcs.SubmissionStatus
        ORDER BY pcs.SubmissionStatus = 'Approved' DESC, `Rank` ASC
    """, (contest_id,))
    
    # Check if user has submitted
    user_submitted = False
    user_voted_photos = []
    
    if 'user_id' in session:
        user_photos = execute_query("""
            SELECT p.PhotoID
            FROM Photo p
            INNER JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
            WHERE p.UserID = %s AND pcs.ContestID = %s
        """, (session['user_id'], contest_id))
        user_submitted = len(user_photos) > 0 if user_photos else False
        
        # Get photos user has already voted for
        voted = execute_query(
            "SELECT PhotoID FROM Votes WHERE UserID = %s AND ContestID = %s",
            (session['user_id'], contest_id)
        )
        user_voted_photos = [v['PhotoID'] for v in voted] if voted else []
    
    return render_template('contest_detail.html', 
                         contest=contest, 
                         leaderboard=leaderboard, 
                         user_submitted=user_submitted,
                         user_voted_photos=user_voted_photos)

# ============================================
# PHOTO SUBMISSION
# ============================================
@app.route('/submit_photo/<int:contest_id>', methods=['GET', 'POST'])
@login_required
def submit_photo(contest_id):
    """Submit photo to contest"""
    contest = execute_query(
        "SELECT * FROM Contest WHERE ContestID = %s",
        (contest_id,),
        fetch_one=True
    )
    
    if not contest:
        flash('Contest not found', 'danger')
        return redirect(url_for('contests'))
    
    # Get user's current coins
    user = execute_query(
        "SELECT Coins FROM User WHERE UserID = %s",
        (session['user_id'],),
        fetch_one=True
    )
    user_coins = user['Coins'] if user and user['Coins'] is not None else 0
    entry_fee = contest['Entry_fee'] if contest['Entry_fee'] is not None else 0
    
    if request.method == 'POST':
        title = request.form.get('title')
        photo_file = request.files.get('photo')
        
        if not title or not photo_file:
            flash('Title and photo are required', 'danger')
            return redirect(url_for('submit_photo', contest_id=contest_id))
        
        if not allowed_file(photo_file.filename):
            flash('Invalid file type. Allowed: png, jpg, jpeg, gif', 'danger')
            return redirect(url_for('submit_photo', contest_id=contest_id))
        
        # Save file
        filename = secure_filename(f"{session['user_id']}_{int(datetime.now().timestamp())}_{photo_file.filename}")
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        photo_file.save(filepath)
        
        # Use stored procedure to submit photo (it handles coin deduction)
        db_filepath = f"uploads/{filename}"
        result = call_procedure('sp_submit_photo_to_contest', 
                              (session['user_id'], contest_id, title, db_filepath))
        
        if result and len(result) > 0:
            message = result[0].get('Message', '')
            if 'successfully' in message.lower():
                flash(f'Photo submitted successfully! {entry_fee} coins deducted.', 'success')
                return redirect(url_for('contest_detail', contest_id=contest_id))
            else:
                # Failed - delete uploaded file
                if os.path.exists(filepath):
                    os.remove(filepath)
                flash(message, 'danger')
        else:
            if os.path.exists(filepath):
                os.remove(filepath)
            flash('Submission failed. Please try again.', 'danger')
    
    return render_template('submit_photo.html', contest=contest, user_coins=user_coins, entry_fee=entry_fee)

# ============================================
# VOTING
# ============================================
@app.route('/vote/<int:photo_id>/<int:contest_id>', methods=['POST'])
@login_required
def vote(photo_id, contest_id):
    """Cast vote on a photo"""
    # First check if the contest is active
    contest = execute_query(
        "SELECT Status FROM Contest WHERE ContestID = %s",
        (contest_id,),
        fetch_one=True
    )
    
    if not contest:
        flash('Contest not found!', 'danger')
        return redirect(url_for('contests'))
    
    if contest['Status'] != 'Active':
        flash('You can only vote in active contests!', 'warning')
        return redirect(url_for('contest_detail', contest_id=contest_id))
    
    # Check if the photo is actually in this contest and approved
    submission = execute_query("""
        SELECT pcs.SubmissionStatus, p.UserID 
        FROM PhotoContestSubmission pcs 
        JOIN Photo p ON pcs.PhotoID = p.PhotoID 
        WHERE pcs.PhotoID = %s AND pcs.ContestID = %s
    """, (photo_id, contest_id), fetch_one=True)
    
    if not submission:
        flash('This photo is not part of this contest!', 'danger')
        return redirect(url_for('contest_detail', contest_id=contest_id))
    
    if submission['SubmissionStatus'] != 'Approved':
        flash('You can only vote for approved photos!', 'warning')
        return redirect(url_for('contest_detail', contest_id=contest_id))
    
    # Check if user is voting on their own photo
    if submission['UserID'] == session['user_id']:
        flash('You cannot vote on your own photo!', 'danger')
        return redirect(url_for('contest_detail', contest_id=contest_id))
    
    try:
        # Try to insert the vote
        success = execute_query(
            "INSERT INTO Votes (UserID, PhotoID, ContestID) VALUES (%s, %s, %s)",
            (session['user_id'], photo_id, contest_id),
            commit=True
        )
        
        if success is not None:
            flash('Vote cast successfully!', 'success')
        else:
            flash('An error occurred while casting your vote.', 'danger')
            
    except Error as e:
        error_msg = str(e)
        if 'duplicate entry' in error_msg.lower():
            flash('You have already voted for this photo!', 'warning')
        else:
            flash(f'Vote failed: {error_msg}', 'danger')
    
    return redirect(url_for('contest_detail', contest_id=contest_id))

# ============================================
# PHOTO MANAGEMENT (UPDATE/DELETE)
# ============================================
@app.route('/photo/<int:photo_id>/edit', methods=['GET', 'POST'])
@login_required
def edit_photo(photo_id):
    """Edit photo title"""
    photo = execute_query(
        "SELECT * FROM Photo WHERE PhotoID = %s AND UserID = %s",
        (photo_id, session['user_id']),
        fetch_one=True
    )
    
    if not photo:
        flash('Photo not found or unauthorized', 'danger')
        return redirect(url_for('dashboard'))
    
    if request.method == 'POST':
        new_title = request.form.get('title')
        
        success = execute_query(
            "UPDATE Photo SET Title = %s WHERE PhotoID = %s",
            (new_title, photo_id),
            commit=True
        )
        
        if success is not None:
            flash('Photo title updated successfully!', 'success')
            return redirect(url_for('dashboard'))
        else:
            flash('Update failed', 'danger')
    
    return render_template('edit_photo.html', photo=photo)

@app.route('/photo/<int:photo_id>/delete', methods=['POST'])
@login_required
def delete_photo(photo_id):
    """Delete photo"""
    photo = execute_query(
        "SELECT * FROM Photo WHERE PhotoID = %s AND UserID = %s",
        (photo_id, session['user_id']),
        fetch_one=True
    )
    
    if not photo:
        flash('Photo not found or unauthorized', 'danger')
        return redirect(url_for('dashboard'))
    
    # Delete file
    filepath = os.path.join('static', photo['FilePath'])
    if os.path.exists(filepath):
        os.remove(filepath)
    
    # Delete from database
    success = execute_query(
        "DELETE FROM Photo WHERE PhotoID = %s",
        (photo_id,),
        commit=True
    )
    
    if success is not None:
        flash('Photo deleted successfully!', 'success')
    else:
        flash('Delete failed', 'danger')
    
    return redirect(url_for('dashboard'))

# ============================================
# ADMIN ROUTES
# ============================================
@app.route('/admin/login', methods=['GET', 'POST'])
def admin_login():
    """Admin login"""
    if request.method == 'POST':
        email = request.form.get('email')
        password = request.form.get('password')
        
        admin = execute_query(
            "SELECT * FROM Admin WHERE Email = %s",
            (email,),
            fetch_one=True
        )
        
        if admin and check_password_hash(admin['Password_hash'], password):
            session['admin_id'] = admin['AdminID']
            session['admin_name'] = admin['Name']
            flash(f'Welcome, Admin {admin["Name"]}!', 'success')
            return redirect(url_for('admin_dashboard'))
        else:
            flash('Invalid credentials', 'danger')
    
    return render_template('admin_login.html')

@app.route('/admin/register', methods=['GET', 'POST'])
def admin_register():
    """Admin registration - accessible from admin login page"""
    if request.method == 'POST':
        name = request.form.get('name')
        email = request.form.get('email')
        password = request.form.get('password')
        confirm_password = request.form.get('confirm_password')
        admin_secret = request.form.get('admin_secret')
        
        # Simple secret code check (you can change this)
        if admin_secret != "admin123":
            flash('Invalid admin secret code', 'danger')
            return redirect(url_for('admin_register'))
        
        if not all([name, email, password, confirm_password]):
            flash('All fields are required', 'danger')
            return redirect(url_for('admin_register'))
        
        if password != confirm_password:
            flash('Passwords do not match', 'danger')
            return redirect(url_for('admin_register'))
        
        # Hash password
        hashed_password = generate_password_hash(password)
        
        # Check if admin exists
        existing_admin = execute_query(
            "SELECT * FROM Admin WHERE Email = %s",
            (email,),
            fetch_one=True
        )
        
        if existing_admin:
            flash('Admin email already registered', 'danger')
            return redirect(url_for('admin_register'))
        
        # Insert admin
        success = execute_query(
            "INSERT INTO Admin (Name, Email, Password_hash) VALUES (%s, %s, %s)",
            (name, email, hashed_password),
            commit=True
        )
        
        if success:
            flash('Admin account created successfully! Please login.', 'success')
            return redirect(url_for('admin_login'))
        else:
            flash('Admin registration failed', 'danger')
    
    return render_template('admin_register.html')

@app.route('/admin/dashboard')
@admin_required
def admin_dashboard():
    """Admin dashboard"""
    total_users = execute_query("SELECT COUNT(*) as count FROM User", fetch_one=True)
    total_contests = execute_query("SELECT COUNT(*) as count FROM Contest", fetch_one=True)
    total_photos = execute_query("SELECT COUNT(*) as count FROM Photo", fetch_one=True)
    total_votes = execute_query("SELECT COUNT(*) as count FROM Votes", fetch_one=True)
    
    recent_submissions = execute_query("""
        SELECT pcs.*, p.Title AS PhotoTitle, u.Name AS UserName, c.Title AS ContestTitle
        FROM PhotoContestSubmission pcs
        INNER JOIN Photo p ON pcs.PhotoID = p.PhotoID
        INNER JOIN User u ON p.UserID = u.UserID
        INNER JOIN Contest c ON pcs.ContestID = c.ContestID
        ORDER BY pcs.SubmissionTimestamp DESC
        LIMIT 10
    """)
    
    return render_template('admin_dashboard.html',
                         total_users=total_users['count'],
                         total_contests=total_contests['count'],
                         total_photos=total_photos['count'],
                         total_votes=total_votes['count'],
                         submissions=recent_submissions)

@app.route('/admin/contests/create', methods=['GET', 'POST'])
@admin_required
def create_contest():
    """Create new contest"""
    if request.method == 'POST':
        title = request.form.get('title')
        start_date = request.form.get('start_date')
        end_date = request.form.get('end_date')
        max_participants = request.form.get('max_participants')
        prize_points = request.form.get('prize_points')
        entry_fee = request.form.get('entry_fee')
        
        success = execute_query("""
            INSERT INTO Contest (Title, StartDate, EndDate, Max_participants, 
                               Prize_points, Entry_fee, Manager_id)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
        """, (title, start_date, end_date, max_participants, prize_points, 
              entry_fee, session['admin_id']), commit=True)
        
        if success:
            flash('Contest created successfully!', 'success')
            return redirect(url_for('admin_dashboard'))
        else:
            flash('Contest creation failed', 'danger')
    
    return render_template('create_contest.html')

@app.route('/admin/submissions/<int:submission_id>/approve', methods=['POST'])
@admin_required
def approve_submission(submission_id):
    """Approve photo submission"""
    success = execute_query(
        "UPDATE PhotoContestSubmission SET SubmissionStatus = 'Approved' WHERE SubmissionID = %s",
        (submission_id,),
        commit=True
    )
    
    if success is not None:
        flash('Submission approved!', 'success')
    else:
        flash('Approval failed', 'danger')
    
    return redirect(url_for('admin_dashboard'))

@app.route('/admin/contest/<int:contest_id>/finalize', methods=['POST'])
@admin_required
def finalize_contest(contest_id):
    """Finalize contest and award prizes"""
    result = call_procedure('sp_award_prize_to_winner', (contest_id,))
    
    if result:
        flash('Contest finalized and prizes awarded!', 'success')
    else:
        flash('Finalization failed', 'danger')
    
    return redirect(url_for('admin_dashboard'))

# ============================================
# API ENDPOINTS (for AJAX)
# ============================================
@app.route('/api/user/stats')
@login_required
def api_user_stats():
    """Get user statistics as JSON"""
    stats = execute_query(
        "SELECT * FROM vw_user_dashboard WHERE UserID = %s",
        (session['user_id'],),
        fetch_one=True
    )
    return jsonify(stats)

@app.route('/api/contest/<int:contest_id>/leaderboard')
def api_contest_leaderboard(contest_id):
    """Get contest leaderboard as JSON"""
    leaderboard = execute_query(
        "SELECT * FROM vw_contest_leaderboard WHERE ContestID = %s ORDER BY `Rank`",
        (contest_id,)
    )
    return jsonify(leaderboard)

@app.route('/api/admin/update-statuses', methods=['POST'])
def api_update_statuses():
    """Update all contest statuses based on current time"""
    try:
        connection = get_db_connection()
        cursor = connection.cursor()
        
        # Update statuses
        cursor.execute("""
            UPDATE Contest
            SET Status = CASE
                WHEN NOW() < StartDate THEN 'Upcoming'
                WHEN NOW() BETWEEN StartDate AND EndDate THEN 'Active'
                WHEN NOW() > EndDate THEN 'Completed'
                ELSE Status
            END
            WHERE Status NOT IN ('Cancelled')
        """)
        
        connection.commit()
        updated_count = cursor.rowcount
        
        return jsonify({'success': True, 'updated': updated_count})
    except Error as e:
        return jsonify({'success': False, 'error': str(e)}), 500
    finally:
        if connection and connection.is_connected():
            cursor.close()
            connection.close()

# ============================================
# ERROR HANDLERS
# ============================================
@app.errorhandler(404)
def not_found(error):
    return render_template('404.html'), 404

@app.errorhandler(500)
def internal_error(error):
    return render_template('500.html'), 500

# ============================================
# RUN APP
# ============================================
if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)