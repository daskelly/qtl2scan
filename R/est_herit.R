#' Estimate heritability with a linear mixed model
#'
#' Estimate the heritability of a set of traits via a linear mixed
#' model, with possible allowance for covariates.
#'
#' @param pheno A matrix of phenotypes, individuals x phenotypes.
#' @param kinship A kinship matrix.
#' @param addcovar An optional matrix of additive covariates.
#' @param reml If true, use REML; otherwise, use maximimum likelihood.
#' @param cores Number of CPU cores to use, for parallel calculations.
#' (If \code{0}, use \code{\link[parallel]{detectCores}}.)
#' Alternatively, this can be links to a set of cluster sockets, as
#' produced by \code{\link[parallel]{makeCluster}}.
#' @param ... Additional control parameters (see details).
#'
#' @return A vector of estimated heritabilities, corresponding to the
#' columns in \code{pheno}.
#'
#' @details
#' We fit the model \eqn{y = X \beta + \epsilon}{y = Xb + e} where
#' \eqn{\epsilon}{e} is multivariate normal with mean 0 and covariance
#' matrix \eqn{\sigma^2 [h^2 (2 K) + I]}{sigmasq*[hsq*2*K+I]} where
#' \eqn{K} is the kinship matrix and \eqn{I} is the identity matrix.
#'
#' For each of the inputs, the row names are used as
#' individual identifiers, to align individuals.
#'
#' If \code{reml=TRUE}, restricted maximum likelihood (reml) is used
#' to estimate the heritability, separately for each phenotype.
#'
#' Additional control parameters include \code{tol} for the tolerance
#' for convergence, \code{quiet} for controlling whether messages will
#' be display, \code{max_batch} for the maximum number of phenotypes
#' in a batch, and \code{check_boundary} for whether the 0 and 1
#' boundary values for the estimated heritability will be checked
#' explicitly.
#'
#' @examples
#' # load qtl2geno package for data and genoprob calculation
#' library(qtl2geno)
#'
#' # read data
#' iron <- read_cross2(system.file("extdata", "iron.zip", package="qtl2geno"))
#'
#' # insert pseudomarkers into map
#' map <- insert_pseudomarkers(iron$gmap, step=1)
#'
#' # calculate genotype probabilities
#' probs <- calc_genoprob(iron, map, error_prob=0.002)
#'
#' # kinship matrix
#' kinship <- calc_kinship(probs)
#'
#' # grab phenotypes and covariates; ensure that covariates have names attribute
#' pheno <- iron$pheno
#' covar <- match(iron$covar$sex, c("f", "m")) # make numeric
#' names(covar) <- rownames(iron$covar)
#'
#' # perform genome scan
#' hsq <- est_herit(pheno, kinship, covar)
#'
#' @export
est_herit <-
    function(pheno, kinship, addcovar=NULL, reml=TRUE, cores=1, ...)
{
    dotargs <- list(...)
    tol <- grab_dots(dotargs, "tol", 1e-12)
    stopifnot(tol > 0)
    quiet <- grab_dots(dotargs, "quiet", TRUE)
    max_batch <- grab_dots(dotargs, "max_batch", NULL)
    check_boundary <- grab_dots(dotargs, "check_boundary", TRUE)
    check_extra_dots(dotargs, c("tol", "quiet", "max_batch",
                                "check_boundary"))

    # force things to be matrices
    if(!is.matrix(pheno))
        pheno <- as.matrix(pheno)
    if(!is.null(addcovar) && !is.matrix(addcovar))
        addcovar <- as.matrix(addcovar)

    # check that kinship matrices are square with same IDs
    if(!is.matrix(kinship) || nrow(kinship) != ncol(kinship) || any(rownames(kinship) != colnames(kinship)))
        stop("kinship should be a square matrix with common row and column names")
    kinshipIDs <- rownames(kinship)

    # multiply kinship matrix by 2; rest is using 2*kinship
    # see Almasy & Blangero (1998) http://doi.org/10.1086/301844
    kinship <- double_kinship(kinship)

    # find individuals in common across all arguments
    # and drop individuals with missing covariates or missing *all* phenotypes
    ind2keep <- get_common_ids(kinshipIDs, addcovar, complete.cases=TRUE)
    ind2keep <- get_common_ids(ind2keep, rownames(pheno)[rowSums(!is.na(pheno)) > 0])
    if(length(ind2keep)<=2) {
        if(length(ind2keep)==0)
            stop("No individuals in common.")
        else
            stop("Only ", length(ind2keep), " individuals in common: ",
                 paste(ind2keep, collapse=":"))
    }

    # make sure addcovar is full rank when we add an intercept
    addcovar <- drop_depcols(addcovar, TRUE, tol)

    # batch phenotypes by missing values
    phe_batches <- batch_cols(pheno[ind2keep,,drop=FALSE], max_batch)

    # set up parallel analysis
    cores <- setup_cluster(cores)
    if(!quiet && n_cores(cores)>1) {
        message(" - Using ", n_cores(cores), " cores")
        quiet <- TRUE # make the rest quiet
    }

    # to contain the results
    hsq <- rep(NA, ncol(pheno))
    names(hsq) <- colnames(pheno)
    n <- nullLL <- hsq

    # loop over batches of phenotypes with the same pattern of NAs
    for(batch in seq_along(phe_batches)) {

        # info about batch
        omit <- phe_batches[[batch]]$omit # ind to omit
        phecol <- phe_batches[[batch]]$cols # phenotype columns in batch

        # individuals to keep in this batch
        these2keep <- ind2keep
        if(length(omit)>0) these2keep <- ind2keep[-omit]
        n[phecol] <- length(these2keep)
        if(length(these2keep) <= 2) next # not enough individuals; skip this batch

        # subset the rest
        K <- kinship[these2keep, these2keep]
        ac <- addcovar; if(!is.null(ac)) ac <- ac[these2keep,,drop=FALSE]
        ph <- pheno[these2keep,phecol,drop=FALSE]

        # eigen decomposition of kinship matrix
        Ke <- decomp_kinship(K, cores=cores)

        # fit LMM for each phenotype, one at a time
        nullresult <- calc_hsq_clean(Ke, ph, ac, NULL, FALSE, reml, cores,
                                     check_boundary, tol)
        hsq[phecol] <- nullresult$hsq
        nullLL <- nullresult$loglik
    }

    attr(hsq, "sample_size") <- n
    attr(hsq, "log10lik") <- nullLL/log(10)

    hsq
}
