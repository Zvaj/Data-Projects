-- Explorartory Data Analysis (EDA)

SELECT * 
FROM layoffs_staging2; 

SELECT MAX(total_laid_off)
FROM layoffs_staging2; # the max amount of people laid off were 12k

SELECT * 
FROM layoffs_staging2
ORDER BY total_laid_off DESC;

SELECT MAX(total_laid_off), MAX(percentage_laid_off)
FROM layoffs_staging2; # as we can see here, the entire company was laid off

SELECT * 
FROM layoffs_staging2
WHERE percentage_laid_off = 1
;

SELECT * 
FROM layoffs_staging2
WHERE percentage_laid_off = 1
ORDER BY total_laid_off DESC
; # Katerra, a construction company laid off 2434 people

SELECT * 
FROM layoffs_staging2
WHERE percentage_laid_off = 1
ORDER BY funds_raised_millions DESC
; 
 
SELECT COUNT(percentage_laid_off)
FROM layoffs_staging2
WHERE percentage_laid_off = 1
; # a total of 116 companies laid off 100% of their employees 

SELECT company, SUM(total_laid_off)
FROM layoffs_staging2
GROUP BY company
ORDER BY 2 DESC; # sum of people laid off by company

SELECT MIN(`date`), MAX(`date`) 
FROM layoffs_staging2; #started in 2020, so around when pandemic got bad 

SELECT industry, SUM(total_laid_off)
FROM layoffs_staging2
GROUP BY industry
ORDER BY 2 DESC; #Consumer and retail were hit the hardest (probably due to COVID)

SELECT country, SUM(total_laid_off)
FROM layoffs_staging2
GROUP BY country
ORDER BY 2 DESC; # US laid off the most people. 
	# Would be nice to see it via population sized, but that is a differnt dataset in itself
	# there may be other confounding variables that we need to take into consideration

SELECT YEAR(`date`), SUM(total_laid_off) # YEAR(`date`) gives us the year only of the date
FROM layoffs_staging2
GROUP BY YEAR(`date`)
ORDER BY 1 DESC; # we can see here that 2022 had the most total laid offs
	# please keep in mind that 2023 only has 3 months of this dataset
    
SELECT stage, SUM(total_laid_off) 
FROM layoffs_staging2
GROUP BY stage
ORDER BY 2 DESC;

SELECT company, AVG(percentage_laid_off) 
FROM layoffs_staging2
GROUP BY company
ORDER BY 2 DESC; # does not help us that much

# sum of laid_off by yyyy-mm
SELECT SUBSTRING(`date`,1,7) AS `MONTH`, SUM(total_laid_off)
FROM layoffs_staging2
WHERE SUBSTRING(`date`,1,7) IS NOT NULL # cannot use `MONTH` here, must be substring
GROUP BY `MONTH`
ORDER BY 1 ASC; 

# Doing a Rolling Sum of what's above
WITH Rolling_Total AS 
(
SELECT SUBSTRING(`date`,1,7) AS `MONTH`, SUM(total_laid_off) AS total_off
FROM layoffs_staging2
WHERE SUBSTRING(`date`,1,7) IS NOT NULL 
GROUP BY `MONTH`
ORDER BY 1 ASC
)
SELECT `MONTH`, total_off,
SUM(total_off) OVER(ORDER BY `MONTH`) AS rolling_total
FROM Rolling_Total;


SELECT company, SUM(total_laid_off)
FROM layoffs_staging2
gROUP BY company
ORDER BY 2 DESC;

SELECT company, YEAR(`date`), SUM(total_laid_off)
FROM layoffs_staging2
gROUP BY company, YEAR(`date`)
ORDER BY company DESC;

SELECT company, YEAR(`date`), SUM(total_laid_off)
FROM layoffs_staging2
gROUP BY company, YEAR(`date`)
ORDER BY 3 DESC;

# CTE
WITH company_year AS 
(
SELECT company, YEAR(`date`), SUM(total_laid_off)
FROM layoffs_staging2
GROUP BY company, YEAR(`date`)
)
SELECT *
FROM company_year;

# laid off highest per year
WITH company_year (company, years, total_laid_off) AS 
(
SELECT company, YEAR(`date`), SUM(total_laid_off)
FROM layoffs_staging2
gROUP BY company, YEAR(`date`)
)
SELECT *, DENSE_RANK() OVER (PARTITION BY years ORDER BY total_laid_off DESC) AS ranking
FROM company_year
WHERE years IS NOT NULL
ORDER BY ranking;

# Top 5 companies by layoffs per year
WITH company_year (company, years, total_laid_off) AS 
(
SELECT company, YEAR(`date`), SUM(total_laid_off)
FROM layoffs_staging2
GROUP BY company, YEAR(`date`)
), Company_Year_Rank AS
(SELECT *, DENSE_RANK() OVER (PARTITION BY years ORDER BY total_laid_off DESC) AS ranking
FROM company_year
WHERE years IS NOT NULL
)
SELECT * 
FROM Company_Year_Rank 
WHERE ranking <= 5
;



