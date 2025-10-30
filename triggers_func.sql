-- ============================================
-- SECTION 0: DATABASE SETUP
-- ============================================
DROP DATABASE IF EXISTS photo_contest_system;
CREATE DATABASE photo_contest_system;
USE photo_contest_system;

-- ============================================
-- SECTION 1: TABLE CREATION (No Changes)
-- ============================================

CREATE TABLE User (
    UserID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password_hash VARCHAR(255) NOT NULL,
    Coins INT DEFAULT 10,
    CONSTRAINT chk_coins CHECK (Coins >= 0),
    INDEX idx_email (Email)
);

CREATE TABLE Admin (
    AdminID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password_hash VARCHAR(255) NOT NULL
);

CREATE TABLE Contest (
    ContestID INT PRIMARY KEY AUTO_INCREMENT,
    Title VARCHAR(200) NOT NULL,
    StartDate DATETIME NOT NULL,
    EndDate DATETIME NOT NULL,
    Status ENUM('Upcoming', 'Active', 'Completed', 'Cancelled') DEFAULT 'Upcoming',
    Max_participants INT DEFAULT 100,
    Prize_points INT DEFAULT 0,
    Entry_fee INT DEFAULT 5,
    Result VARCHAR(500),
    Manager_id INT,
    CONSTRAINT chk_dates CHECK (EndDate >= StartDate),
    CONSTRAINT chk_max_participants CHECK (Max_participants > 0),
    CONSTRAINT chk_prize_points CHECK (Prize_points >= 0),
    CONSTRAINT chk_entry_fee CHECK (Entry_fee >= 0),
    INDEX idx_status (Status),
    INDEX idx_dates (StartDate, EndDate),
    FOREIGN KEY (Manager_id) REFERENCES Admin(AdminID) ON DELETE SET NULL
);

CREATE TABLE Photo (
    PhotoID INT PRIMARY KEY AUTO_INCREMENT,
    Title VARCHAR(200) NOT NULL,
    FilePath VARCHAR(500) NOT NULL,
    UploadDate DATETIME DEFAULT CURRENT_TIMESTAMP,
    UserID INT NOT NULL,
    FOREIGN KEY (UserID) REFERENCES User(UserID) ON DELETE CASCADE,
    INDEX idx_user_photo (UserID),
    INDEX idx_upload_date (UploadDate)
);

CREATE TABLE PhotoContestSubmission (
    SubmissionID INT PRIMARY KEY AUTO_INCREMENT,
    PhotoID INT NOT NULL,
    ContestID INT NOT NULL,
    SubmissionTimestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    SubmissionStatus ENUM('Pending', 'Approved', 'Rejected') DEFAULT 'Pending',
    FOREIGN KEY (PhotoID) REFERENCES Photo(PhotoID) ON DELETE CASCADE,
    FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE,
    UNIQUE KEY unique_submission (PhotoID, ContestID),
    INDEX idx_contest_submissions (ContestID),
    INDEX idx_photo_submissions (PhotoID)
);

CREATE TABLE Votes (
    VoteID INT PRIMARY KEY AUTO_INCREMENT,
    UserID INT NOT NULL,
    PhotoID INT NOT NULL,
    ContestID INT NOT NULL,
    Vote_timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (UserID) REFERENCES User(UserID) ON DELETE CASCADE,
    FOREIGN KEY (PhotoID) REFERENCES Photo(PhotoID) ON DELETE CASCADE,
    FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE,
    UNIQUE KEY unique_vote (UserID, PhotoID, ContestID),
    INDEX idx_contest_votes (ContestID),
    INDEX idx_photo_votes (PhotoID),
    INDEX idx_user_votes (UserID)
);

CREATE TABLE Contest_Audit (
    AuditID INT PRIMARY KEY AUTO_INCREMENT,
    ContestID INT NOT NULL,
    Action VARCHAR(100),
    Timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_contest (ContestID)
);


-- ============================================
-- SECTION 2: TRIGGERS (REFACTORED)
-- ============================================

-- REFACTOR: Removed trg_check_and_deduct_coins_before_submission
-- This logic is now handled in sp_submit_photo_to_contest

-- This trigger is still necessary
DELIMITER //
CREATE TRIGGER trg_check_contest_status_before_submission
BEFORE INSERT ON PhotoContestSubmission
FOR EACH ROW
BEGIN
    DECLARE v_start DATETIME;
    DECLARE v_end DATETIME;
    DECLARE v_status ENUM('Upcoming', 'Active', 'Completed', 'Cancelled');
    
    SELECT StartDate, EndDate, Status INTO v_start, v_end, v_status
    FROM Contest 
    WHERE ContestID = NEW.ContestID;
    
    IF v_status IN ('Completed', 'Cancelled') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot submit to completed or cancelled contests.';
    END IF;
    
    IF NOW() < v_start THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'This contest has not started yet.';
    END IF;
    
    IF NOW() > v_end THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'This contest has already ended.';
    END IF;
END//
DELIMITER ;

-- This trigger is unchanged
DELIMITER //
CREATE TRIGGER trg_prevent_self_voting
BEFORE INSERT ON Votes
FOR EACH ROW
BEGIN
    DECLARE photo_owner INT;
    
    SELECT UserID INTO photo_owner 
    FROM Photo 
    WHERE PhotoID = NEW.PhotoID;
    
    IF photo_owner = NEW.UserID THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'You cannot vote on your own photo.';
    END IF;
END//
DELIMITER ;

-- This trigger is unchanged
DELIMITER //
CREATE TRIGGER trg_log_contest_completion
AFTER UPDATE ON Contest
FOR EACH ROW
BEGIN
    IF OLD.Status != 'Completed' AND NEW.Status = 'Completed' THEN
        INSERT INTO Contest_Audit (ContestID, Action, Timestamp)
        VALUES (NEW.ContestID, 'Contest Completed', NOW());
    END IF;
END//
DELIMITER ;

-- ============================================
-- SECTION 3: STORED PROCEDURES (MODIFIED)
-- ============================================

-- Procedure 1: Register new user (Unchanged)
DELIMITER //
CREATE PROCEDURE sp_register_user(
    IN p_name VARCHAR(100),
    IN p_email VARCHAR(100),
    IN p_password VARCHAR(255)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF (SELECT COUNT(*) FROM User WHERE Email = p_email) > 0 THEN
            SELECT 'Error: Email address is already in use.' AS Message;
        ELSE
            SELECT 'Error: User registration failed' AS Message;
        END IF;
    END;
    
    START TRANSACTION;
    INSERT INTO User (Name, Email, Password_hash, Coins)
    VALUES (p_name, p_email, SHA2(p_password, 256), 10);
    COMMIT;
    SELECT 'User registered successfully' AS Message, LAST_INSERT_ID() AS UserID;
END//
DELIMITER ;

-- Procedure 2: Submit photo to contest (REFACTORED TO FIX BUG)
DELIMITER //
CREATE PROCEDURE sp_submit_photo_to_contest(
    IN p_user_id INT,
    IN p_contest_id INT,
    IN p_title VARCHAR(200),
    IN p_filepath VARCHAR(500)
)
BEGIN
    DECLARE v_photo_id INT;
    DECLARE v_sql_state CHAR(5);
    DECLARE v_message TEXT;
    DECLARE v_user_coins INT;
    DECLARE v_entry_fee INT;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        GET DIAGNOSTICS CONDITION 1 v_sql_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        SELECT CONCAT('Error: Photo submission failed. ', v_message) AS Message;
    END;
    
    START TRANSACTION;
    
    -- *** BEGIN REFACTOR ***
    -- Logic moved from trigger to procedure
    
    -- 1. Get contest fee and user coins (and lock the user row)
    SELECT COALESCE(Entry_fee, 0) INTO v_entry_fee 
    FROM Contest 
    WHERE ContestID = p_contest_id;
    
    SELECT COALESCE(Coins, 0) INTO v_user_coins 
    FROM User 
    WHERE UserID = p_user_id FOR UPDATE;
    
    -- 2. Check if user has enough coins
    IF v_user_coins < v_entry_fee THEN
        ROLLBACK;
        SELECT 'Error: Insufficient coins to enter this contest.' AS Message;
    ELSE
        -- 3. Deduct coins
        UPDATE User 
        SET Coins = Coins - v_entry_fee
        WHERE UserID = p_user_id;

        -- 4. Insert photo
        INSERT INTO Photo (Title, FilePath, UserID)
        VALUES (p_title, p_filepath, p_user_id);
        SET v_photo_id = LAST_INSERT_ID();
        
        -- 5. Submit to contest (this will still fire the status-check trigger)
        INSERT INTO PhotoContestSubmission (PhotoID, ContestID, SubmissionStatus)
        VALUES (v_photo_id, p_contest_id, 'Pending');
        
        COMMIT;
        SELECT 'Photo submitted successfully' AS Message, v_photo_id AS PhotoID;
    END IF;
    -- *** END REFACTOR ***
    
END//
DELIMITER ;

-- Procedure 3: Cast vote on a photo (Unchanged)
DELIMITER //
CREATE PROCEDURE sp_cast_vote(
    IN p_user_id INT,
    IN p_photo_id INT,
    IN p_contest_id INT
)
BEGIN
    DECLARE v_sql_state CHAR(5);
    DECLARE v_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        GET DIAGNOSTICS CONDITION 1 v_sql_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        
        -- REFACTOR: Handle trigger errors ('45000') and duplicate key errors ('23000') explicitly.
        IF v_sql_state = '45000' THEN -- Custom trigger error (e.g., contest not active)
            IF v_message IS NULL OR v_message = '' THEN
                 SELECT 'Error: Submission failed. Contest is not in a valid state.' AS Message;
            ELSE
                 SELECT v_message AS Message; -- Return the trigger's message
            END IF;
        ELSEIF v_sql_state = '23000' THEN -- Duplicate submission
            SELECT 'Error: This photo has already been submitted to this contest.' AS Message;
        ELSE -- All other unexpected errors
            SELECT CONCAT('Error: Photo submission failed due to an unexpected database error. SQLSTATE: ', v_sql_state) AS Message;
        END IF;
    END;
    
    START TRANSACTION;
    INSERT INTO Votes (UserID, PhotoID, ContestID)
    VALUES (p_user_id, p_photo_id, p_contest_id);
    COMMIT;
    SELECT 'Vote cast successfully' AS Message;
END//
DELIMITER ;

-- Procedure 4: Calculate contest winner (Unchanged)
DELIMITER //
CREATE PROCEDURE sp_calculate_contest_winner(IN p_contest_id INT)
BEGIN
    SELECT 
        p.PhotoID,
        p.Title AS PhotoTitle,
        u.Name AS PhotographerName,
        COUNT(v.VoteID) AS TotalVotes,
        RANK() OVER (ORDER BY COUNT(v.VoteID) DESC) AS `Rank`
    FROM Photo p
    INNER JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
    INNER JOIN User u ON p.UserID = u.UserID
    LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = p_contest_id
    WHERE pcs.ContestID = p_contest_id AND pcs.SubmissionStatus = 'Approved'
    DECLARE v_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        GET DIAGNOSTICS CONDITION 1 v_sql_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        
        -- REFACTOR: Handle self-voting ('45000') and duplicate key errors ('23000') explicitly.
        IF v_sql_state = '23000' THEN -- Unique constraint (duplicate vote)
            SELECT 'Error: You have already voted for this photo in this contest.' AS Message;
        ELSEIF v_sql_state = '45000' THEN -- Custom trigger error (self-voting)
            IF v_message IS NULL OR v_message = '' THEN
                 SELECT 'Error: Vote failed. A custom rule was violated (e.g., self-voting).' AS Message;
            ELSE
                 SELECT v_message AS Message; -- Just return the trigger's message directly
            END IF;
        ELSE -- All other unexpected errors
            SELECT CONCAT('Error: Vote casting failed due to an unexpected database error. SQLSTATE: ', v_sql_state) AS Message;
        END IF;
    END;
    
    START TRANSACTION;
    
    SELECT Prize_points INTO v_prize_points
    FROM Contest
    WHERE ContestID = p_contest_id;
    
    SELECT p.UserID, p.Title, u.Name INTO v_winner_user_id, v_winner_photo_title, v_winner_photographer_name
    FROM Photo p
    INNER JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
    INNER JOIN User u ON p.UserID = u.UserID
    LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = p_contest_id
    WHERE pcs.ContestID = p_contest_id AND pcs.SubmissionStatus = 'Approved'
    GROUP BY p.PhotoID, p.UserID, p.Title, u.Name
    ORDER BY COUNT(v.VoteID) DESC
    LIMIT 1;
    
    SELECT COUNT(*) INTO v_photo_count
    FROM PhotoContestSubmission
    WHERE ContestID = p_contest_id AND SubmissionStatus = 'Approved';
    
    IF v_photo_count = 0 THEN
        UPDATE Contest
        SET Result = 'Contest completed with no approved submissions.',
            Status = 'Completed'
        WHERE ContestID = p_contest_id;
    
    ELSEIF v_winner_user_id IS NULL THEN
        UPDATE Contest
        SET Result = 'Contest completed with no votes cast.',
            Status = 'Completed'
        WHERE ContestID = p_contest_id;

    ELSE
        UPDATE User
        SET Coins = Coins + v_prize_points
        WHERE UserID = v_winner_user_id;
        
        UPDATE Contest
        SET Result = CONCAT('Winner: ', v_winner_photographer_name, ' with photo "', v_winner_photo_title, '" (User ID: ', v_winner_user_id, ')'),
            Status = 'Completed'
        WHERE ContestID = p_contest_id;
    END IF;
    
    COMMIT;
    
    IF v_winner_user_id IS NOT NULL THEN
        SELECT 'Prize awarded successfully' AS Message, 
               v_winner_user_id AS WinnerUserID,
               v_prize_points AS PrizeAwarded;
    ELSE
        SELECT 'Contest completed, no winner declared (no votes or submissions).' AS Message;
    END IF;
END//
DELIMITER ;

-- Procedure 6: Get user statistics (Unchanged)
DELIMITER //
CREATE PROCEDURE sp_get_user_statistics(IN p_user_id INT)
BEGIN
    SELECT 
        u.Name,
        u.Email,
        u.Coins,
        COUNT(DISTINCT p.PhotoID) AS TotalPhotosUploaded,
        COUNT(DISTINCT pcs.SubmissionID) AS TotalSubmissions,
        COUNT(DISTINCT v.VoteID) AS TotalVotesCast,
        (SELECT COUNT(*) FROM Votes WHERE PhotoID IN 
            (SELECT PhotoID FROM Photo WHERE UserID = p_user_id)) AS VotesReceived
    FROM User u
    LEFT JOIN Photo p ON u.UserID = p.UserID
    LEFT JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
    LEFT JOIN Votes v ON u.UserID = v.UserID
    WHERE u.UserID = p_user_id
    GROUP BY u.UserID, u.Name, u.Email, u.Coins;
END//
DELIMITMTER ;

-- Procedure 7: Update contest status (Unchanged)
DELIMITER //
CREATE PROCEDURE sp_update_all_contest_statuses()
BEGIN
    UPDATE Contest
    SET Status = 'Active'
    WHERE NOW() BETWEEN StartDate AND EndDate
    AND Status = 'Upcoming';
    
    UPDATE Contest
    SET Status = 'Completed'
    WHERE NOW() > EndDate
    AND Status != 'Cancelled'
    AND Status != 'Completed';
    
    SELECT ROW_COUNT() AS UpdatedContests;
END//
DELIMITER ;

-- ============================================
-- SECTION 4: FUNCTIONS (Unchanged)
-- ============================================

-- Voting is free, so this just returns TRUE
DELIMITER //
CREATE FUNCTION fn_can_user_vote(p_user_id INT) 
RETURNS BOOLEAN
DETERMINISTIC
BEGIN
    RETURN TRUE;
END//
DELIMITER ;

DELIMITER //
CREATE FUNCTION fn_get_photo_votes(p_photo_id INT, p_contest_id INT)
RETURNS INT
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_vote_count INT;
    SELECT COUNT(*) INTO v_vote_count
    FROM Votes
    WHERE PhotoID = p_photo_id AND ContestID = p_contest_id;
    RETURN v_vote_count;
END//
DELIMITER ;

DELIMITER //
CREATE FUNCTION fn_has_user_voted(p_user_id INT, p_photo_id INT, p_contest_id INT)
RETURNS BOOLEAN
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_vote_exists INT;
    SELECT COUNT(*) INTO v_vote_exists
    FROM Votes
    WHERE UserID = p_user_id 
      AND PhotoID = p_photo_id 
      AND ContestID = p_contest_id;
    RETURN v_vote_exists > 0;
END//
DELIMITER ;

DELIMITER //
CREATE FUNCTION fn_contest_participation_rate(p_contest_id INT)
RETURNS DECIMAL(5,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_submissions INT;
    DECLARE v_max_participants INT;
    DECLARE v_rate DECIMAL(5,2);
    
    SELECT COUNT(*) INTO v_submissions
    FROM PhotoContestSubmission
    WHERE ContestID = p_contest_id;
    
    SELECT Max_participants INTO v_max_participants
    FROM Contest
    WHERE ContestID = p_contest_id;
    
    IF v_max_participants > 0 THEN
        SET v_rate = (v_submissions / v_max_participants) * 100;
    ELSE
        SET v_rate = 0;
    END IF;
    
    RETURN v_rate;
END//
DELIMITER ;

DELIMITER //
CREATE FUNCTION fn_get_user_rank_in_contest(p_user_id INT, p_contest_id INT)
RETURNS INT
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_rank INT DEFAULT 0;
    
    SELECT COALESCE(user_rank, 0) INTO v_rank
    FROM (
        SELECT 
            p.UserID,
            RANK() OVER (ORDER BY COUNT(v.VoteID) DESC) AS user_rank
        FROM Photo p
        INNER JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
        LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = p_contest_id
        WHERE pcs.ContestID = p_contest_id
        GROUP BY p.UserID
    ) AS ranked_users
    WHERE UserID = p_user_id;
    
    RETURN v_rank;
END//
DELIMITER ;

-- ============================================
-- SECTION 5: VIEWS (No Changes)
-- ============================================
CREATE OR REPLACE VIEW vw_contest_leaderboard AS
SELECT 
    c.ContestID, c.Title AS ContestTitle,
    p.PhotoID, p.Title AS PhotoTitle,
    u.Name AS PhotographerName, u.Email AS PhotographerEmail,
    COUNT(v.VoteID) AS TotalVotes,
    pcs.SubmissionTimestamp,
    RANK() OVER (PARTITION BY c.ContestID ORDER BY COUNT(v.VoteID) DESC) AS `Rank`
FROM Contest c
INNER JOIN PhotoContestSubmission pcs ON c.ContestID = pcs.ContestID
INNER JOIN Photo p ON pcs.PhotoID = p.PhotoID
INNER JOIN User u ON p.UserID = u.UserID
LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = c.ContestID
WHERE pcs.SubmissionStatus = 'Approved'
GROUP BY c.ContestID, c.Title, p.PhotoID, p.Title, u.Name, u.Email, pcs.SubmissionTimestamp;

CREATE OR REPLACE VIEW vw_active_contests AS
SELECT 
    c.ContestID, c.Title, c.StartDate, c.EndDate, c.Status,
    c.Max_participants, c.Prize_points, c.Entry_fee,
    a.Name AS ManagerName,
    COUNT(DISTINCT pcs.PhotoID) AS TotalSubmissions,
    COUNT(DISTINCT v.VoteID) AS TotalVotes,
    TIMESTAMPDIFF(HOUR, NOW(), c.EndDate) AS HoursRemaining
FROM Contest c
LEFT JOIN Admin a ON c.Manager_id = a.AdminID
LEFT JOIN PhotoContestSubmission pcs ON c.ContestID = pcs.ContestID
LEFT JOIN Votes v ON c.ContestID = v.ContestID
WHERE c.Status = 'Active'
GROUP BY c.ContestID, c.Title, c.StartDate, c.EndDate, c.Status, 
         c.Max_participants, c.Prize_points, c.Entry_fee, a.Name;

CREATE OR REPLACE VIEW vw_user_dashboard AS
SELECT 
    u.UserID, u.Name, u.Email, u.Coins,
    COUNT(DISTINCT p.PhotoID) AS PhotosUploaded,
    COUNT(DISTINCT pcs.SubmissionID) AS ContestParticipations,
    COUNT(DISTDINCT v.VoteID) AS VotesCast,
    (SELECT COUNT(*) FROM Votes WHERE PhotoID IN 
        (SELECT PhotoID FROM Photo WHERE UserID = u.UserID)) AS VotesReceived
FROM User u
LEFT JOIN Photo p ON u.UserID = p.UserID
LEFT JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
LEFT JOIN Votes v ON u.UserID = v.UserID
GROUP BY u.UserID, u.Name, u.Email, u.Coins;

CREATE OR REPLACE VIEW vw_top_photographers AS
SELECT 
    u.UserID, u.Name, u.Email,
    COUNT(DISTINCT p.PhotoID) AS TotalPhotos,
    COUNT(DISTINCT v.VoteID) AS TotalVotesReceived,
    COUNT(DISTINCT pcs.ContestID) AS ContestsParticipated,
    ROUND(COUNT(DISTINCT v.VoteID) / NULLIF(COUNT(DISTINCT p.PhotoID), 0), 2) AS AvgVotesPerPhoto
FROM User u
LEFT JOIN Photo p ON u.UserID = p.UserID
LEFT JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
LEFT JOIN Votes v ON p.PhotoID = v.PhotoID
GROUP BY u.UserID, u.Name, u.Email
HAVING TotalPhotos > 0
ORDER BY TotalVotesReceived DESC;


