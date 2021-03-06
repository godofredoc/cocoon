// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:appengine/appengine.dart';
import 'package:corsac_jwt/corsac_jwt.dart';
import 'package:gcloud/db.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:github/github.dart';
import 'package:googleapis/bigquery/v2.dart' as bigquery;
import 'package:googleapis_auth/auth.dart';
import 'package:graphql/client.dart' hide Cache;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../cocoon_service.dart';
import '../foundation/providers.dart';
import '../foundation/utils.dart';
import '../model/appengine/key_helper.dart';
import '../model/appengine/service_account_info.dart';
import '../service/access_client_provider.dart';
import '../service/bigquery.dart';
import '../service/github_service.dart';

/// Name of the default git branch.
const String kDefaultBranchName = 'master';

class Config {
  Config(this._db, this._cache) : assert(_db != null);

  final DatastoreDB _db;

  final CacheService _cache;

  /// List of Github presubmit supported repos.
  static const Set<String> supportedRepos = <String>{
    'engine',
    'flutter',
    'cocoon',
    'packages',
  };

  /// List of Github presubmit supported repos.
  static const Set<String> checksSupportedRepos = <String>{
    'flutter/cocoon',
    'flutter/engine',
    'flutter/packages',
  };

  @visibleForTesting
  static const String configCacheName = 'config';

  @visibleForTesting
  static const Duration configCacheTtl = Duration(hours: 12);

  Logging get loggingService => ss.lookup(#appengine.logging) as Logging;

  Future<List<String>> _getFlutterBranches() async {
    final Uint8List cacheValue = await _cache.getOrCreate(
      configCacheName,
      'flutterBranches',
      createFn: () => getBranches(Providers.freshHttpClient, loggingService, twoSecondLinearBackoff),
      ttl: configCacheTtl,
    );

    return String.fromCharCodes(cacheValue).split(',');
  }

  Future<String> _getSingleValue(String id) async {
    final Uint8List cacheValue = await _cache.getOrCreate(
      configCacheName,
      id,
      createFn: () => _getValueFromDatastore(id),
      ttl: configCacheTtl,
    );

    return String.fromCharCodes(cacheValue);
  }

  Future<Uint8List> _getValueFromDatastore(String id) async {
    final CocoonConfig cocoonConfig = CocoonConfig()
      ..id = id
      ..parentKey = _db.emptyKey;
    final CocoonConfig result = await _db.lookupValue<CocoonConfig>(cocoonConfig.key);

    return Uint8List.fromList(result.value.codeUnits);
  }

  // GitHub App properties.
  Future<String> get githubPrivateKey => _getSingleValue('githubapp_private_pem');
  Future<String> get githubPublicKey => _getSingleValue('githubapp_public_pem');
  Future<String> get githubAppId => _getSingleValue('githubapp_id');
  Future<Map<String, dynamic>> get githubAppInstallations async {
    final String installations = await _getSingleValue('githubapp_installations');
    return jsonDecode(installations) as Map<String, dynamic>;
  }

  DatastoreDB get db => _db;

  Future<List<String>> get flutterBranches => _getFlutterBranches();

  Future<String> get oauthClientId => _getSingleValue('OAuthClientId');

  Future<String> get githubOAuthToken => _getSingleValue('GitHubPRToken');

  String get wrongBaseBranchPullRequestMessage => 'This pull request was opened against a branch other than '
      '_${kDefaultBranchName}_. Since Flutter pull requests should not '
      'normally be opened against branches other than $kDefaultBranchName, I '
      'have changed the base to $kDefaultBranchName. If this was intended, you '
      'may modify the base back to {{branch}}. See the [Release Process]'
      '(https://github.com/flutter/flutter/wiki/Release-process) for information '
      'about how other branches get updated.\n\n'
      '__Reviewers__: Use caution before merging pull requests to branches other '
      'than $kDefaultBranchName, unless this is an intentional hotfix/cherrypick.';

  String wrongHeadBranchPullRequestMessage(String branch) =>
      'This pull request is trying merge the branch $branch, which is the name '
      'of a release branch. This is usually a mistake. See '
      '[Tree Hygiene](https://github.com/flutter/flutter/wiki/Tree-hygiene) '
      'for detailed instructions on how to contribute to the Flutter project. '
      'In particular, ensure that before you start coding, you create your '
      'feature branch off of _${kDefaultBranchName}_.\n\n'
      'This PR has been closed. If you are sure you want to merge $branch, you '
      'may re-open this issue.';

  String get releaseBranchPullRequestMessage => 'This pull request was opened '
      'from and to a release candidate branch. This should only be done as part '
      'of the official [Flutter release process]'
      '(https://github.com/flutter/flutter/wiki/Release-process). If you are '
      'attempting to make a regular contribution to the Flutter project, please '
      'close this PR and follow the instructions at [Tree Hygiene]'
      '(https://github.com/flutter/flutter/wiki/Tree-hygiene) for detailed '
      'instructions on contributing to Flutter.\n\n'
      '__Reviewers__: Use caution before merging pull requests to release '
      'branches. Ensure the proper procedure has been followed.';

  Future<String> get webhookKey => _getSingleValue('WebhookKey');

  String get missingTestsPullRequestMessage => 'It looks like this pull '
      'request may not have tests. Please make sure to add tests before merging. '
      'If you need an exemption to this rule, contact Hixie on the #hackers '
      'channel in [Chat](https://github.com/flutter/flutter/wiki/Chat).'
      '\n\n'
      '__Reviewers__: Read the [Tree Hygiene page]'
      '(https://github.com/flutter/flutter/wiki/Tree-hygiene#how-to-review-code) '
      'and make sure this patch meets those guidelines before LGTMing.';

  String get goldenBreakingChangeMessage => 'Changes to golden files are considered breaking changes, so consult '
      '[Handling Breaking Changes](https://github.com/flutter/flutter/wiki/Tree-hygiene#handling-breaking-changes) '
      'to proceed. While there are exceptions to this rule, if this patch modifies '
      'an existing golden file, it is probably not an exception. Only new golden '
      'file tests, or downstream changes like those from skia updates are '
      'considered non-breaking.\n\n'
      'For more guidance, visit '
      '[Writing a golden file test for `package:flutter`](https://github.com/flutter/flutter/wiki/Writing-a-golden-file-test-for-package:flutter).\n\n'
      '__Reviewers__: Read the [Tree Hygiene page](https://github.com/flutter/flutter/wiki/Tree-hygiene#how-to-review-code) '
      'and make sure this patch meets those guidelines before LGTMing.';

  String get goldenTriageMessage => 'Nice merge! 🎉\n'
      'It looks like this PR made changes to golden files. If these changes have '
      'not been triaged as a tryjob, be sure to visit '
      '[Flutter Gold](https://flutter-gold.skia.org/?query=source_type%3Dflutter) '
      'to triage the results when post-submit testing has completed. The status '
      'of these tests can be seen on the '
      '[Flutter Dashboard](https://flutter-dashboard.appspot.com/build.html).\n'
      'Also, be sure to include this change in the [Changelog](https://github.com/flutter/flutter/wiki/Changelog).\n\n'
      'For more information about working with golden files, see the wiki page '
      '[Writing a Golden File Test for package:flutter/flutter](https://github.com/flutter/flutter/wiki/Writing-a-golden-file-test-for-package:flutter).';

  int get maxTaskRetries => 2;

  /// The number of times to retry a LUCI job on infra failures.
  int get luciTryInfraFailureRetries => 2;

  /// The default number of commit shown in flutter build dashboard.
  int get commitNumber => 30;

  // TODO(keyonghan): update all existing APIs to use this reference, https://github.com/flutter/flutter/issues/48987.
  KeyHelper get keyHelper => KeyHelper(applicationContext: context.applicationContext);

  String get cqLabelName => 'CQ+1';

  String get defaultBranch => kDefaultBranchName;

  // Default number of commits to return for benchmark dashboard.
  int get maxRecords => 50;

  // Repository status context for github status.
  String get flutterBuild => 'flutter-build';

  // Repository status description for github status.
  String get flutterBuildDescription => 'Flutter build is currently broken. Please do not merge this '
      'PR unless it contains a fix to the broken build.';

  RepositorySlug get flutterSlug => RepositorySlug('flutter', 'flutter');

  String get waitingForTreeToGoGreenLabelName => 'waiting for tree to go green';

  Future<ServiceAccountInfo> get deviceLabServiceAccount async {
    final String rawValue = await _getSingleValue('DevicelabServiceAccount');
    return ServiceAccountInfo.fromJson(json.decode(rawValue) as Map<String, dynamic>);
  }

  Future<ServiceAccountCredentials> get taskLogServiceAccount async {
    final String rawValue = await _getSingleValue('TaskLogServiceAccount');
    return ServiceAccountCredentials.fromJson(json.decode(rawValue));
  }

  /// The names of autoroller accounts for the repositories.
  ///
  /// These accounts should not need reviews before merging. See
  /// https://github.com/flutter/flutter/wiki/Autorollers
  Set<String> get rollerAccounts => const <String>{
        'skia-flutter-autoroll',
        'engine-flutter-autoroll',
      };

  /// A List of builders for LUCI
  List<Map<String, dynamic>> get luciBuilders => <Map<String, String>>[
        <String, String>{
          'name': 'Linux',
          'repo': 'flutter',
          'taskName': 'linux_bot',
        },
        <String, String>{
          'name': 'Mac',
          'repo': 'flutter',
          'taskName': 'mac_bot',
        },
        <String, String>{
          'name': 'Windows',
          'repo': 'flutter',
          'taskName': 'windows_bot',
        },
        <String, String>{
          'name': 'Linux Coverage',
          'repo': 'flutter',
        },
        <String, String>{
          'name': 'Linux Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Fuchsia',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Android AOT Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Android Debug Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Android AOT Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Android Debug Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac iOS Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac iOS Engine Profile',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac iOS Engine Release',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Windows Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Windows Android AOT Engine',
          'repo': 'engine',
        }
      ];

  /// A List of try builders for LUCI
  List<Map<String, dynamic>> get luciTryBuilders => <Map<String, String>>[
        <String, String>{
          'name': 'Cocoon',
          'repo': 'cocoon',
        },
        <String, String>{
          'name': 'Linux',
          'repo': 'flutter',
          'taskName': 'linux_bot',
        },
        <String, String>{
          'name': 'Windows',
          'repo': 'flutter',
          'taskName': 'windows_bot',
        },
        <String, String>{
          'name': 'Linux Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Fuchsia',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Android AOT Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Android Debug Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Linux Web Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Android AOT Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Android Debug Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac iOS Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Windows Host Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Windows Android AOT Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Windows Web Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'Mac Web Engine',
          'repo': 'engine',
        },
        <String, String>{
          'name': 'fuchsia_ctl',
          'repo': 'packages',
        },
      ];

  Future<String> generateJsonWebToken() async {
    final String privateKey = await githubPrivateKey;
    final String publicKey = await githubPublicKey;
    final JWTBuilder builder = JWTBuilder();
    final DateTime now = DateTime.now();
    builder
      ..issuer = await githubAppId
      ..issuedAt = now
      ..expiresAt = now.add(const Duration(minutes: 10));
    final JWTRsaSha256Signer signer = JWTRsaSha256Signer(privateKey: privateKey, publicKey: publicKey);
    final JWT signedToken = builder.getSignedToken(signer);
    return signedToken.toString();
  }

  Future<String> generateGithubToken(String owner, String repository) async {
    final Map<String, dynamic> appInstallations = await githubAppInstallations;
    final String appInstallation = appInstallations['$owner/$repository']['installation_id'] as String;
    final String jsonWebToken = await generateJsonWebToken();
    final Map<String, String> headers = <String, String>{
      'Authorization': 'Bearer $jsonWebToken',
      'Accept': 'application/vnd.github.machine-man-preview+json'
    };
    final http.Response response =
        await http.post('https://api.github.com/app/installations/$appInstallation/access_tokens', headers: headers);
    final Map<String, dynamic> jsonBody = jsonDecode(response.body) as Map<String, dynamic>;
    return jsonBody['token'] as String;
  }

  Future<GitHub> createGitHubClient(String owner, String repository) async {
    final Map<String, dynamic> appInstallations = await githubAppInstallations;
    String githubToken;
    if (appInstallations.containsKey('$owner/$repository')) {
      githubToken = await generateGithubToken(owner, repository);
    } else {
      githubToken = await githubOAuthToken;
    }
    return GitHub(auth: Authentication.withToken(githubToken));
  }

  Future<GraphQLClient> createGitHubGraphQLClient() async {
    final HttpLink httpLink = HttpLink(
      uri: 'https://api.github.com/graphql',
      headers: <String, String>{
        'Accept': 'application/vnd.github.antiope-preview+json',
      },
    );

    final String token = await githubOAuthToken;
    final AuthLink _authLink = AuthLink(
      getToken: () async => 'Bearer $token',
    );

    final Link link = _authLink.concat(httpLink);

    return GraphQLClient(
      cache: InMemoryCache(),
      link: link,
    );
  }

  Future<GraphQLClient> createCirrusGraphQLClient() async {
    final HttpLink httpLink = HttpLink(
      uri: 'https://api.cirrus-ci.com/graphql',
    );

    return GraphQLClient(
      cache: InMemoryCache(),
      link: httpLink,
    );
  }

  Future<bigquery.TabledataResourceApi> createTabledataResourceApi() async {
    final AccessClientProvider accessClientProvider = AccessClientProvider(await deviceLabServiceAccount);
    return await BigqueryService(accessClientProvider).defaultTabledata();
  }

  Future<GithubService> createGithubService(String owner, String repository) async {
    final GitHub github = await createGitHubClient(owner, repository);
    return GithubService(github);
  }

  bool githubPresubmitSupportedRepo(String repositoryName) {
    return supportedRepos.contains(repositoryName);
  }

  Future<RepositorySlug> repoNameForBuilder(String builderName) async {
    final List<Map<String, dynamic>> builders = luciTryBuilders;
    final Map<String, dynamic> builderConfig = builders.firstWhere(
      (Map<String, dynamic> builder) => builder['name'] == builderName,
      orElse: () => <String, String>{'repo': ''},
    );
    final String repoName = builderConfig['repo'] as String;
    // If there is no builder config for the builderName then we
    // return null. This is to allow the code calling this method
    // to skip changes that depend on builder configurations.
    if (repoName.isEmpty) {
      return null;
    }
    return RepositorySlug('flutter', repoName);
  }

  bool isChecksSupportedRepo(RepositorySlug slug) {
    return checksSupportedRepos.contains('${slug.owner}/${slug.name}');
  }
}

@Kind(name: 'CocoonConfig', idType: IdType.String)
class CocoonConfig extends Model {
  @StringProperty(propertyName: 'ParameterValue')
  String value;
}

class InvalidConfigurationException implements Exception {
  const InvalidConfigurationException(this.id);

  final String id;

  @override
  String toString() => 'Invalid configuration value for $id';
}
