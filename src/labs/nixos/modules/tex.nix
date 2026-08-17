{ pkgs, ... }:

{
  # Composed rather than texliveMedium, which is 2.5 GiB and spends most of it on
  # things a headless lab cannot use: collection-texworks is a Qt editor,
  # collection-binextra carries tlcockpit and texplate — two Java tools, and the
  # 568 MiB JDK behind them — and collection-context brings ConTeXt, clisp and
  # mupdf. scheme-medium reaches all of that through collections, and the texlive
  # API has no way to subtract from a scheme, so name the parts instead.
  #
  # The set below is what the labs' own fixtures actually resolve: article,
  # report and beamer, with amsmath, babel, fontspec, geometry, graphicx,
  # hyperref, parskip, tikz and xspace, driven through latexmk, pdflatex,
  # xelatex, lualatex, biber, bibtex and makeindex. collection-luatex is here
  # because lualatex is one of the engines; the bibliography tools are named
  # individually because collection-bibtexextra's bib2gls is the other JDK.
  environment.systemPackages = [
    (pkgs.texlive.withPackages (
      ps: with ps; [
        scheme-small
        collection-fontsrecommended
        collection-luatex
        collection-mathscience
        collection-pictures
        biber
        biblatex
        latexdiff
        latexmk
        texdoc
      ]
    ))
    pkgs.texlab
  ];
}
