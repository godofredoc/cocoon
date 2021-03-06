// Copyright 2020 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:cocoon_service/src/model/appengine/service_account_info.dart';
import 'package:cocoon_service/src/model/luci/buildbucket.dart';
import 'package:cocoon_service/src/model/luci/push_message.dart' as push_message;
import 'package:cocoon_service/src/service/github_status_service.dart';
import 'package:cocoon_service/src/service/luci_build_service.dart';
import 'package:github/github.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import '../src/datastore/fake_cocoon_config.dart';
import '../src/utilities/mocks.dart';

void main() {
  ServiceAccountInfo serviceAccountInfo;
  FakeConfig config;
  MockBuildBucketClient mockBuildBucketClient;
  LuciBuildService service;
  GithubStatusService githubStatusService;
  MockGitHub mockGitHub;
  MockRepositoriesService mockRepositoriesService;
  RepositorySlug slug;

  const Build macBuild = Build(
    id: 999,
    builderId: BuilderId(
      project: 'flutter',
      bucket: 'prod',
      builder: 'MacDoesNotExist',
    ),
    status: Status.scheduled,
  );

  const Build linuxBuild = Build(
    id: 998,
    builderId: BuilderId(
      project: 'flutter',
      bucket: 'prod',
      builder: 'Linux',
    ),
    status: Status.scheduled,
  );

  setUp(() {
    serviceAccountInfo = const ServiceAccountInfo(email: 'abc@abcd.com');
    config = FakeConfig(deviceLabServiceAccountValue: serviceAccountInfo);
    mockBuildBucketClient = MockBuildBucketClient();
    service = LuciBuildService(config, mockBuildBucketClient, serviceAccountInfo);
    githubStatusService = GithubStatusService(config, service);
    mockGitHub = MockGitHub();
    mockRepositoriesService = MockRepositoriesService();
    when(mockGitHub.repositories).thenAnswer((_) {
      return mockRepositoriesService;
    });
    config.githubClient = mockGitHub;
    config.luciTryBuildersValue = <Map<String, dynamic>>[];
    slug = RepositorySlug('flutter', 'flutter');
  });
  group('setBuildsPendingStatus', () {
    test('Empty builds do nothing', () async {
      when(mockBuildBucketClient.batch(any)).thenAnswer((_) async {
        return const BatchResponse(
          responses: <Response>[
            Response(
              searchBuilds: SearchBuildsResponse(
                builds: <Build>[],
              ),
            ),
          ],
        );
      });
      await githubStatusService.setBuildsPendingStatus(123, 'abc', slug);
      verifyNever(mockGitHub.repositories);
    });

    test('A build list creates status', () async {
      when(mockBuildBucketClient.batch(any)).thenAnswer((_) async {
        return const BatchResponse(
          responses: <Response>[
            Response(
              searchBuilds: SearchBuildsResponse(
                builds: <Build>[linuxBuild],
              ),
            ),
          ],
        );
      });
      config.luciTryBuildersValue = (json.decode('[{"name": "Linux"}]') as List<dynamic>).cast<Map<String, dynamic>>();
      final List<RepositoryStatus> repositoryStatuses = <RepositoryStatus>[];
      when(mockRepositoriesService.listStatuses(any, any)).thenAnswer((_) {
        return Stream<RepositoryStatus>.fromIterable(repositoryStatuses);
      });
      await githubStatusService.setBuildsPendingStatus(123, 'abc', slug);
      expect(
          verify(mockRepositoriesService.createStatus(any, any, captureAny)).captured.first.toJson(),
          jsonDecode(
              '{"state":"pending","target_url":"","description":"Flutter LUCI Build: Linux","context":"Linux"}'));
    });
    test('Only builds in luciTryBuilders create statuses', () async {
      when(mockBuildBucketClient.batch(any)).thenAnswer((_) async {
        return const BatchResponse(
          responses: <Response>[
            Response(
              searchBuilds: SearchBuildsResponse(
                builds: <Build>[linuxBuild, macBuild],
              ),
            ),
          ],
        );
      });
      config.luciTryBuildersValue = (json.decode('[{"name": "Linux"}]') as List<dynamic>).cast<Map<String, dynamic>>();
      final List<RepositoryStatus> repositoryStatuses = <RepositoryStatus>[];
      when(mockRepositoriesService.listStatuses(any, any)).thenAnswer((_) {
        return Stream<RepositoryStatus>.fromIterable(repositoryStatuses);
      });
      await githubStatusService.setBuildsPendingStatus(123, 'abc', slug);
      expect(
          verify(mockRepositoriesService.createStatus(any, any, captureAny)).captured.first.toJson(),
          jsonDecode(
              '{"state":"pending","target_url":"","description":"Flutter LUCI Build: Linux","context":"Linux"}'));
    });
  });
  group('setPendingStatus', () {
    setUp(() {});

    test('Status not updated if builder does not exist', () async {
      final bool success = await githubStatusService.setPendingStatus(
        ref: '123hash',
        builderName: 'MacNoExists',
        buildUrl: 'myurl',
        slug: slug,
      );
      expect(success, isFalse);
      verifyNever(mockGitHub.repositories);
    });

    test('Status not updated if it is already pending', () async {
      when(mockBuildBucketClient.batch(any)).thenAnswer((_) async {
        return const BatchResponse(
          responses: <Response>[
            Response(
              searchBuilds: SearchBuildsResponse(
                builds: <Build>[macBuild],
              ),
            ),
          ],
        );
      });
      final List<RepositoryStatus> repositoryStatuses = <RepositoryStatus>[
        RepositoryStatus()
          ..context = 'Mac'
          ..state = 'pending'
          ..targetUrl = 'url'
      ];
      when(mockRepositoriesService.listStatuses(any, any)).thenAnswer((_) {
        return Stream<RepositoryStatus>.fromIterable(repositoryStatuses);
      });
      final bool success = await githubStatusService.setPendingStatus(
        ref: '123hash',
        builderName: 'Mac',
        buildUrl: 'url',
        slug: slug,
      );
      expect(success, isFalse);
      verifyNever(mockRepositoriesService.createStatus(any, any, captureAny));
    });

    test('Status updated when not pending or url is different', () async {
      List<RepositoryStatus> repositoryStatuses = <RepositoryStatus>[
        RepositoryStatus()
          ..context = 'Mac'
          ..state = 'failed'
          ..targetUrl = 'url'
      ];
      when(mockRepositoriesService.listStatuses(any, any)).thenAnswer((_) {
        return Stream<RepositoryStatus>.fromIterable(repositoryStatuses);
      });
      final bool success = await githubStatusService.setPendingStatus(
        ref: '123hash',
        builderName: 'Mac',
        buildUrl: 'url',
        slug: slug,
      );
      expect(success, isTrue);
      expect(
          verify(mockRepositoriesService.createStatus(any, any, captureAny)).captured.first.toJson(),
          jsonDecode(
              '{"state":"pending","target_url":"url?reload=30","description":"Flutter LUCI Build: Mac","context":"Mac"}'));
      repositoryStatuses = <RepositoryStatus>[
        RepositoryStatus()
          ..context = 'Mac'
          ..state = 'pending'
          ..targetUrl = 'url'
      ];
      await githubStatusService.setPendingStatus(
        ref: '123hash',
        builderName: 'Mac',
        buildUrl: 'different_url',
        slug: slug,
      );
      expect(
          verify(mockRepositoriesService.createStatus(any, any, captureAny)).captured.first.toJson(),
          jsonDecode(
              '{"state":"pending","target_url":"different_url?reload=30","description":"Flutter LUCI Build: Mac","context":"Mac"}'));
    });
  });

  group('setCompletedStatus', () {
    setUp(() {});
    test('Builder does not exist', () async {
      await githubStatusService.setCompletedStatus(
          ref: '123hash',
          builderName: 'MacNoExists',
          buildUrl: 'myurl',
          slug: slug,
          result: push_message.Result.canceled);
      verifyNever(mockGitHub.repositories);
    });

    test('Status updated to cancelled', () async {
      final List<RepositoryStatus> repositoryStatuses = <RepositoryStatus>[
        RepositoryStatus()
          ..context = 'Mac'
          ..state = 'pending'
          ..targetUrl = 'url'
      ];
      when(mockRepositoriesService.listStatuses(any, any)).thenAnswer((_) {
        return Stream<RepositoryStatus>.fromIterable(repositoryStatuses);
      });
      await githubStatusService.setCompletedStatus(
          ref: '123hash', builderName: 'Mac', buildUrl: 'url', slug: slug, result: push_message.Result.canceled);
      expect(verify(mockRepositoriesService.createStatus(any, any, captureAny)).captured.first.toJson(),
          jsonDecode('{"state":"failure","target_url":"url","description":"Flutter LUCI Build: Mac","context":"Mac"}'));
    });
    test('Status updated to success', () async {
      final List<RepositoryStatus> repositoryStatuses = <RepositoryStatus>[
        RepositoryStatus()
          ..context = 'Mac'
          ..state = 'pending'
          ..targetUrl = 'url'
      ];
      when(mockRepositoriesService.listStatuses(any, any)).thenAnswer((_) {
        return Stream<RepositoryStatus>.fromIterable(repositoryStatuses);
      });
      await githubStatusService.setCompletedStatus(
          ref: '123hash', builderName: 'Mac', buildUrl: 'url', slug: slug, result: push_message.Result.success);
      expect(verify(mockRepositoriesService.createStatus(any, any, captureAny)).captured.first.toJson(),
          jsonDecode('{"state":"success","target_url":"url","description":"Flutter LUCI Build: Mac","context":"Mac"}'));
    });
  });
}
