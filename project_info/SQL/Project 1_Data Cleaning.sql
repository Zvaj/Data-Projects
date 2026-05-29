-- Data Cleaning
# Step 0: Preparing the data
	-- click on'create a new schema in the connected server'
    -- Remane the schema to what you want
    -- go to your schemas on the left hand side and right click tables of the schema
    -- click on 'table data import wizard' and browse your data, and do what needs to be done from there

# you can double-click the schema on the left tab or use the USE schema 
USE world_layoffs; 

SELECT * 
FROM layoffs; #layoffs around the world from 2020

# What we will be doing: 
	-- 1. Remove duplicates 
	-- 2. Standardize the data
	-- 3. Null values or blank values
	-- 4. Remove any cols or rows that are not necessary 

# We made this so that the raw dataset doesn't get change
CREATE TABLE layoffs_staging
LIKE layoffs; 

#notice table was only made, not data info
SELECT *
FROM layoffs_staging;

#populate the staging layoffs_staging w/ the data info from layoffs
INSERT layoffs_staging
SELECT * 
FROM layoffs;

-- Removing duplicates 
SELECT *,
ROW_NUMBER() OVER(
	PARTITION BY company, industry, total_laid_off, percentage_laid_off, `date`) AS row_num
FROM layoffs_staging;

	# CTE creation w/ a few cols
WITH duplicate_cte AS
(
SELECT *,
ROW_NUMBER() OVER(
	PARTITION BY company, location, industry, total_laid_off, percentage_laid_off, `date`) AS row_num
FROM layoffs_staging
)
SELECT *
FROM duplicate_cte
WHERE row_num >= 2;

	# double check if it is truly a duplicate
SELECT * 
FROM layoffs_staging
WHERE company = 'Oda'; #notice that they ARE NOT a duplicate b/c of country difference 


	# CTE creation w/ all cols
WITH duplicate_cte AS
(
SELECT *,
ROW_NUMBER() OVER(
	PARTITION BY company, location, industry, total_laid_off, percentage_laid_off, 
    `date`, stage, country, funds_raised_millions) AS row_num #list all cols
FROM layoffs_staging
)
SELECT *
FROM duplicate_cte
WHERE row_num >= 2;

	# double check if it is truly a duplicate
SELECT * 
FROM layoffs_staging
WHERE company = 'Casper'; #notice that row 1 & 3 are dupes; only remove 1, not all of them


	# Trying to delete dupes w/ CTE
WITH duplicate_cte AS
(
SELECT *,
ROW_NUMBER() OVER(
	PARTITION BY company, location, industry, total_laid_off, percentage_laid_off, 
    `date`, stage, country, funds_raised_millions) AS row_num #list all cols
FROM layoffs_staging
)
DELETE
FROM duplicate_cte
WHERE row_num >= 2; # causes an error as expected


	# to deal w/ dupes. create a new table
CREATE TABLE `layoffs_staging2` (
  `company` text,
  `location` text,
  `industry` text,
  `total_laid_off` int DEFAULT NULL,
  `percentage_laid_off` text,
  `date` text,
  `stage` text,
  `country` text,
  `funds_raised_millions` int DEFAULT NULL,
  `row_num` INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

SELECT * 
FROM layoffs_staging2;

INSERT INTO layoffs_staging2
SELECT *,
ROW_NUMBER() OVER(
	PARTITION BY company, location, percentage_laid_off, `date`, 
    stage, country, funds_raised_millions) AS row_num
FROM layoffs_staging;

SELECT * 
FROM layoffs_staging2
WHERE row_num >= 2;

DELETE # had to go to 'Query' and 'Reconnect server'
FROM layoffs_staging2
WHERE row_num >= 2;

SELECT * 
FROM layoffs_staging2
WHERE row_num >= 2; #notice that DELETE deleted the dupes

SELECT * 
FROM layoffs_staging2; 




-- Standardization 
SELECT DISTINCT(company)
FROM layoffs_staging2; 

	#trimming it
SELECT DISTINCT(TRIM(company))
FROM layoffs_staging2; 

	# good to look at side-by-side 
SELECT company, TRIM(company)
FROM layoffs_staging2; 

	# updating the old company to match the trim one
UPDATE layoffs_staging2
SET company = TRIM(company) #remember that trim takes off white space
; 

	# checking them side-by-side after the update to see if they match; they should
SELECT company, TRIM(company)
FROM layoffs_staging2; 

	# now we look at the next col, industry
SELECT DISTINCT(industry)
FROM
    layoffs_staging2
; #notice there is a 'CryptoCurrency' & 'Crypto Currency'

SELECT DISTINCT(industry)
FROM layoffs_staging2
ORDER BY industry 
; #notice there is a 'CryptoCurrency' & 'Crypto Currency' & 'Crypto'

	# selecting all and looking at the crypto row
SELECT * 
FROM layoffs_staging2
WHERE industry LIKE 'Crypto%'
ORDER BY industry
;

	# now that we have identify the crypto%, we will now standardize it by updating
UPDATE layoffs_staging2 
SET industry = 'Crypto'
WHERE industry LIKE 'Crypto%'
; # see how 3 rows was updated 

	# double-check to see that they are all the same 
SELECT DISTINCT(industry)
FROM layoffs_staging2
WHERE industry LIKE 'Crypto%'
;


	# moving onto the next col
SELECT DISTINCT(location)
FROM layoffs_staging2
ORDER BY location 
; #location looks good, now let us look at everything

	# next col
SELECT DISTINCT(country)
FROM layoffs_staging2
ORDER BY 1; # notice 'united states' and ''united states.'

SELECT * 
FROM layoffs_staging2
WHERE country LIKE 'United States%'
; # see which is most common and update the least common to the most common 

	# trailing trim
SELECT DISTINCT country, TRIM(TRAILING '.' FROM country) 
FROM layoffs_staging2
ORDER BY 1
;

	# updating it 
UPDATE layoffs_staging2
SET country = TRIM(TRAILING '.' FROM country)
WHERE country LIKE 'United States%'
;

	# double-check if it has been updaed
SELECT DISTINCT country, TRIM(TRAILING '.' FROM country) 
FROM layoffs_staging2
ORDER BY 1
; # it has

	# Now we look at date, making sure it is in datetime formate
SELECT `date`
FROM layoffs_staging2
;

	#change the format to yyyy/mm/dd
SELECT `date`,
STR_TO_DATE(`date`, '%m/%d/%Y') # need capital Y here to get the 4 y's
FROM layoffs_staging2
; 

	# updating
UPDATE layoffs_staging2
SET `date` = STR_TO_DATE(`date`, '%m/%d/%Y')
; # notice how 2355 rows were updated

	# double checking
SELECT `date`
FROM layoffs_staging2
ORDER BY 1
; # it looks good, but note that the data col is still a 'text' and not a 'date' datatype

	# Altering the table and updating it to the correct data type
ALTER TABLE layoffs_staging2
MODIFY COLUMN `date` DATE
;

SELECT * 
FROM layoffs_staging2
; #looks good now





-- Nulls/Blank values
SELECT * 
FROM layoffs_staging2
WHERE total_laid_off IS NULL #to look for null, IS NOT NULL also exist
;

	# if total_laid_off and percentage_laid_off is null, then it might be useless
SELECT * 
FROM layoffs_staging2
WHERE total_laid_off IS NULL
AND percentage_laid_off IS NULL
;


	# we are going to update the blanks to nulls
UPDATE layoffs_staging2
SET industry = NULL
WHERE industry = ''
;

	# select everything and seeing what is blank and null
SELECT *
FROM layoffs_staging2
WHERE industry IS NULL
OR industry = '' # for blanks
;

	# check to see if AirBnB is populated for the industry
SELECT *
FROM layoffs_staging2
WHERE company = 'Airbnb'
;

	# we see that Airbnb is already populated, 
    # so we will populate the blank with what it should have been
SELECT * 
FROM layoffs_staging2 t1
JOIN layoffs_staging2 t2
	ON t1.company = t2.company
    AND t1.location = t2.location # we are doing this b/c there may be an AIRBNB somewhere else
WHERE (t1.industry IS NULL)
AND t2.industry IS NOT NULL 
;

	# what we are trying do do up above
SELECT t1.industry, t2.industry
FROM layoffs_staging2 t1
JOIN layoffs_staging2 t2
	ON t1.company = t2.company
    AND t1.location = t2.location # we are doing this b/c there may be an AIRBNB somewhere else
WHERE t1.industry IS NULL
AND t2.industry IS NOT NULL 
; # now we must populate the blank 

	# updating it
UPDATE layoffs_staging2 t1 
JOIN layoffs_staging2 t2
	ON t1.company = t2.company
    AND t1.location = t2.location
SET t1.industry = t2.industry
WHERE t1.industry IS NULL
AND t2.industry IS NOT NULL 
;

	# double-checking it
SELECT t1.industry, t2.industry
FROM layoffs_staging2 t1
JOIN layoffs_staging2 t2
	ON t1.company = t2.company
    AND t1.location = t2.location 
WHERE t1.industry IS NULL 
AND t2.industry IS NOT NULL 
; 

SELECT *
FROM layoffs_staging2
WHERE company = 'Airbnb'
; # now Airbnb has been updated
 
 SELECT * 
 FROM layoffs_staging2
 WHERE industry IS NULL
 OR industry = ''
;  # notice that Bally's is blank/null still

	#checking out Bally's
SELECT *
FROM layoffs_staging2
WHERE company LIKE "Bally%"
; # the reason why this is blank/null is because 
	# there wasn't a second one that is populated to populate the not null one

SELECT *
FROM layoffs_staging2
; # we cannot populate the nulls from total_laid_off, perentage_laid_off, 
		# and funds_raised_millions b/c we are missing some data that an help us populate it






-- Row/Col removal 
SELECT * 
FROM layoffs_staging2
WHERE total_laid_off IS NULL
AND percentage_laid_off IS NULL
; # look at the rows and see if they are needed/helpful  
	# when it comes to deleting data, you need to be 100% confident when removing it
    # we are removing it here b/c we don't know if they were even laid off
    

	# we are deleting the rows
DELETE 
FROM layoffs_staging2
WHERE total_laid_off IS NULL
AND percentage_laid_off IS NULL
;


	# double checking
SELECT * 
FROM layoffs_staging2
WHERE total_laid_off IS NULL
AND percentage_laid_off IS NULL
;

SELECT * 
FROM layoffs_staging2; # we still have row_num, delete it

	#dropping the row_num
ALTER TABLE layoffs_staging2
DROP COLUMN row_num
;

SELECT * 
FROM layoffs_staging2;

