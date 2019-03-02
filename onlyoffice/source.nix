{ fetchFromGitHub }:

rec {
  baseName = "onlyoffice-document-server";
  version = "5.2.8";

  src = fetchFromGitHub {
    owner = "ONLYOFFICE";
    repo = "DocumentServer";
    rev = "ONLYOFFICE-DocumentServer-${version}";
    sha256 = "192qj3sf40wxd9793ngww5m2xyshmpyy6pdw350c66zzsa6r15fp";
    fetchSubmodules = true;
  };
}
