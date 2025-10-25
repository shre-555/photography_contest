DROP DATABASE IF EXISTS photo_contest_system;
CREATE DATABASE photo_contest_system;
USE photo_contest_system;

CREATE TABLE User (
    UserID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password VARCHAR(255) NOT NULL,
    Coins INT DEFAULT 10,
    CONSTRAINT chk_coins CHECK (Coins >= 0),
    INDEX idx_email (Email)
);

CREATE TABLE Admin (
    AdminID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password_hash VARCHAR(255) NOT NULL,
    CONSTRAINT chk_admin_email UNIQUE (Email)
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
    UNIQUE KEY unique_submission (PhotoID, ContestID), -- A photo can only be submitted once per contest
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
    UNIQUE KEY unique_vote (UserID, PhotoID, ContestID), -- User can vote only once per photo per contest
    INDEX idx_contest_votes (ContestID),
    INDEX idx_photo_votes (PhotoID),
    INDEX idx_user_votes (UserID)
);


USE photo_contest_system;

-- Trigger 1: Deduct entry fee when submitting to contest (based on contest's entry_fee)
DELIMITER //
CREATE TRIGGER trg_deduct_coins_on_submission
AFTER INSERT ON PhotoContestSubmission
FOR EACH ROW
BEGIN
    DECLARE entry_fee INT;
    DECLARE photo_owner INT;
    
    -- Get the contest's entry fee
    SELECT Entry_fee INTO entry_fee 
    FROM Contest 
    WHERE ContestID = NEW.ContestID;
    
    -- Get the photo owner
    SELECT UserID INTO photo_owner 
    FROM Photo 
    WHERE PhotoID = NEW.PhotoID;
    
    -- Deduct entry fee from user's coins
    UPDATE User 
    SET Coins = Coins - entry_fee
    WHERE UserID = photo_owner;
END//
DELIMITER ;

-- Trigger 2: Prevent submission if user has insufficient coins for entry fee
DELIMITER //
CREATE TRIGGER trg_check_coins_before_submission
BEFORE INSERT ON PhotoContestSubmission
FOR EACH ROW
BEGIN
    DECLARE user_coins INT;
    DECLARE entry_fee INT;
    DECLARE photo_owner INT;
    
    -- Get the contest's entry fee
    SELECT Entry_fee INTO entry_fee 
    FROM Contest 
    WHERE ContestID = NEW.ContestID;
    
    -- Get the photo owner
    SELECT UserID INTO photo_owner 
    FROM Photo 
    WHERE PhotoID = NEW.PhotoID;
    
    -- Get user's coin balance
    SELECT Coins INTO user_coins 
    FROM User 
    WHERE UserID = photo_owner;
    
    -- Check if user has enough coins
    IF user_coins < entry_fee THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Insufficient coins to enter this contest. Check the entry fee.';
    END IF;
END//
DELIMITER ;

-- Trigger 3: Auto-update contest status based on time
DELIMITER //
CREATE TRIGGER trg_auto_update_contest_status
BEFORE INSERT ON Contest
FOR EACH ROW
BEGIN
    IF NEW.StartDate <= NOW() AND NEW.EndDate >= NOW() THEN
        SET NEW.Status = 'Active';
    ELSEIF NEW.StartDate > NOW() THEN
        SET NEW.Status = 'Upcoming';
    ELSEIF NEW.EndDate < NOW() THEN
        SET NEW.Status = 'Completed';
    END IF;
END//
DELIMITER ;

-- Trigger 4: Prevent submission to completed/cancelled contests
DELIMITER //
CREATE TRIGGER trg_check_contest_status_before_submission
BEFORE INSERT ON PhotoContestSubmission
FOR EACH ROW
BEGIN
    DECLARE contest_status VARCHAR(20);
    
    SELECT Status INTO contest_status 
    FROM Contest 
    WHERE ContestID = NEW.ContestID;
    
    IF contest_status IN ('Completed', 'Cancelled') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot submit to completed or cancelled contests.';
    END IF;
END//
DELIMITER ;

-- Trigger 5: Prevent voting on own photos
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

-- Trigger 6: Award coins to contest winner (called manually or via event)
DELIMITER //
CREATE TRIGGER trg_log_contest_completion
AFTER UPDATE ON Contest
FOR EACH ROW
BEGIN
    IF OLD.Status != 'Completed' AND NEW.Status = 'Completed' THEN
        -- Log completion in a separate audit table (if exists)
        INSERT INTO Contest_Audit (ContestID, Action, Timestamp)
        VALUES (NEW.ContestID, 'Contest Completed', NOW());
    END IF;
END//
DELIMITER ;

-- ============================================
-- SECTION 2: STORED PROCEDURES
-- ============================================

-- Procedure 1: Register new user
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
        SELECT 'Error: User registration failed' AS Message;
    END;
    
    START TRANSACTION;
    
    INSERT INTO User (Name, Email, Password, Coins)
    VALUES (p_name, p_email, p_password, 10);
    
    COMMIT;
    SELECT 'User registered successfully' AS Message, LAST_INSERT_ID() AS UserID;
END//
DELIMITER ;

-- Procedure 2: Submit photo to contest
DELIMITER //
CREATE PROCEDURE sp_submit_photo_to_contest(
    IN p_user_id INT,
    IN p_contest_id INT,
    IN p_title VARCHAR(200),
    IN p_filepath VARCHAR(500)
)
BEGIN
    DECLARE v_photo_id INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'Error: Photo submission failed' AS Message;
    END;
    
    START TRANSACTION;
    
    -- Insert photo
    INSERT INTO Photo (Title, FilePath, UserID)
    VALUES (p_title, p_filepath, p_user_id);
    
    SET v_photo_id = LAST_INSERT_ID();
    
    -- Submit to contest
    INSERT INTO PhotoContestSubmission (PhotoID, ContestID, SubmissionStatus)
    VALUES (v_photo_id, p_contest_id, 'Pending');
    
    COMMIT;
    SELECT 'Photo submitted successfully' AS Message, v_photo_id AS PhotoID;
END//
DELIMITER ;

-- Procedure 3: Cast vote on a photo
DELIMITER //
CREATE PROCEDURE sp_cast_vote(
    IN p_user_id INT,
    IN p_photo_id INT,
    IN p_contest_id INT
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'Error: Vote casting failed' AS Message;
    END;
    
    START TRANSACTION;
    
    -- Insert vote (triggers will handle coin deduction and validation)
    INSERT INTO Votes (UserID, PhotoID, ContestID)
    VALUES (p_user_id, p_photo_id, p_contest_id);
    
    COMMIT;
    SELECT 'Vote cast successfully' AS Message;
END//
DELIMITER ;

-- Procedure 4: Calculate contest winner
DELIMITER //
CREATE PROCEDURE sp_calculate_contest_winner(IN p_contest_id INT)
BEGIN
    SELECT 
        p.PhotoID,
        p.Title AS PhotoTitle,
        u.Name AS PhotographerName,
        COUNT(v.VoteID) AS TotalVotes,
        RANK() OVER (ORDER BY COUNT(v.VoteID) DESC) AS Rank
    FROM Photo p
    INNER JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
    INNER JOIN User u ON p.UserID = u.UserID
    LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = p_contest_id
    WHERE pcs.ContestID = p_contest_id AND pcs.SubmissionStatus = 'Approved'
    GROUP BY p.PhotoID, p.Title, u.Name
    ORDER BY TotalVotes DESC;
END//
DELIMITER ;

-- Procedure 5: Award prize to winner
DELIMITER //
CREATE PROCEDURE sp_award_prize_to_winner(IN p_contest_id INT)
BEGIN
    DECLARE v_winner_user_id INT;
    DECLARE v_prize_points INT;
    DECLARE v_winner_photo_title VARCHAR(200);
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'Error: Prize awarding failed' AS Message;
    END;
    
    START TRANSACTION;
    
    -- Get prize points
    SELECT Prize_points INTO v_prize_points
    FROM Contest
    WHERE ContestID = p_contest_id;
    
    -- Find winner (photo with most votes)
    SELECT p.UserID, p.Title INTO v_winner_user_id, v_winner_photo_title
    FROM Photo p
    INNER JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
    LEFT JOIN Votes v ON p.PhotoID = v.PhotoID AND v.ContestID = p_contest_id
    WHERE pcs.ContestID = p_contest_id AND pcs.SubmissionStatus = 'Approved'
    GROUP BY p.PhotoID, p.UserID, p.Title
    ORDER BY COUNT(v.VoteID) DESC
    LIMIT 1;
    
    -- Award coins to winner
    UPDATE User
    SET Coins = Coins + v_prize_points
    WHERE UserID = v_winner_user_id;
    
    -- Update contest result
    UPDATE Contest
    SET Result = CONCAT('Winner: ', v_winner_photo_title, ' (User ID: ', v_winner_user_id, ')'),
        Status = 'Completed'
    WHERE ContestID = p_contest_id;
    
    COMMIT;
    SELECT 'Prize awarded successfully' AS Message, 
           v_winner_user_id AS WinnerUserID,
           v_prize_points AS PrizeAwarded;
END//
DELIMITER ;

-- Procedure 6: Get user statistics
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
DELIMITER ;

-- Procedure 7: Update contest status (can be called periodically)
DELIMITER //
CREATE PROCEDURE sp_update_all_contest_statuses()
BEGIN
    UPDATE Contest
    SET Status = CASE
        WHEN NOW() < StartDate THEN 'Upcoming'
        WHEN NOW() BETWEEN StartDate AND EndDate THEN 'Active'
        WHEN NOW() > EndDate THEN 'Completed'
        ELSE Status
    END
    WHERE Status NOT IN ('Cancelled');
    
    SELECT ROW_COUNT() AS UpdatedContests;
END//
DELIMITER ;

-- ============================================
-- SECTION 3: FUNCTIONS
-- ============================================

-- Function 1: Check if user can vote (has coins)
DELIMITER //
CREATE FUNCTION fn_can_user_vote(p_user_id INT) 
RETURNS BOOLEAN
DETERMINISTIC
BEGIN
    DECLARE v_coins INT;
    
    SELECT Coins INTO v_coins 
    FROM User 
    WHERE UserID = p_user_id;
    
    RETURN v_coins > 0;
END//
DELIMITER ;

-- Function 2: Get total votes for a photo in a contest
DELIMITER //
CREATE FUNCTION fn_get_photo_votes(p_photo_id INT, p_contest_id INT)
RETURNS INT
DETERMINISTIC
BEGIN
    DECLARE v_vote_count INT;
    
    SELECT COUNT(*) INTO v_vote_count
    FROM Votes
    WHERE PhotoID = p_photo_id AND ContestID = p_contest_id;
    
    RETURN v_vote_count;
END//
DELIMITER ;

-- Function 3: Check if user has already voted on a photo
DELIMITER //
CREATE FUNCTION fn_has_user_voted(p_user_id INT, p_photo_id INT, p_contest_id INT)
RETURNS BOOLEAN
DETERMINISTIC
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

-- Function 4: Calculate contest participation rate
DELIMITER //
CREATE FUNCTION fn_contest_participation_rate(p_contest_id INT)
RETURNS DECIMAL(5,2)
DETERMINISTIC
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

-- Function 5: Get user rank in contest (by votes received)
DELIMITER //
CREATE FUNCTION fn_get_user_rank_in_contest(p_user_id INT, p_contest_id INT)
RETURNS INT
DETERMINISTIC
BEGIN
    DECLARE v_rank INT;
    
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
-- SECTION 4: VIEWS
-- ============================================

-- View 1: Contest Leaderboard
CREATE OR REPLACE VIEW vw_contest_leaderboard AS
SELECT 
    c.ContestID,
    c.Title AS ContestTitle,
    p.PhotoID,
    p.Title AS PhotoTitle,
    u.Name AS PhotographerName,
    u.Email AS PhotographerEmail,
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

-- View 2: Active Contests Summary
CREATE OR REPLACE VIEW vw_active_contests AS
SELECT 
    c.ContestID,
    c.Title,
    c.StartDate,
    c.EndDate,
    c.Status,
    c.Max_participants,
    c.Prize_points,
    c.Entry_fee,
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

-- View 3: User Dashboard
CREATE OR REPLACE VIEW vw_user_dashboard AS
SELECT 
    u.UserID,
    u.Name,
    u.Email,
    u.Coins,
    COUNT(DISTINCT p.PhotoID) AS PhotosUploaded,
    COUNT(DISTINCT pcs.SubmissionID) AS ContestParticipations,
    COUNT(DISTINCT v.VoteID) AS VotesCast,
    (SELECT COUNT(*) FROM Votes WHERE PhotoID IN 
        (SELECT PhotoID FROM Photo WHERE UserID = u.UserID)) AS VotesReceived
FROM User u
LEFT JOIN Photo p ON u.UserID = p.UserID
LEFT JOIN PhotoContestSubmission pcs ON p.PhotoID = pcs.PhotoID
LEFT JOIN Votes v ON u.UserID = v.UserID
GROUP BY u.UserID, u.Name, u.Email, u.Coins;

-- View 4: Top Photographers
CREATE OR REPLACE VIEW vw_top_photographers AS
SELECT 
    u.UserID,
    u.Name,
    u.Email,
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

