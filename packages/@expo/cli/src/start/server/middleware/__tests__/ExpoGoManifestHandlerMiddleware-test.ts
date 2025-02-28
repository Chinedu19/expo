import { ExpoConfig } from '@expo/config';
import {
  isMultipartPartWithName,
  parseMultipartMixedResponseAsync,
  MultipartPart,
} from '@expo/multipart-body-parser';
import { vol } from 'memfs';
import nullthrows from 'nullthrows';

import { asMock } from '../../../../__tests__/asMock';
import { getProjectAsync } from '../../../../api/getProject';
import { APISettings } from '../../../../api/settings';
import { getUserAsync } from '../../../../api/user/user';
import {
  mockExpoRootChain,
  mockSelfSigned,
} from '../../../../utils/__tests__/fixtures/certificates';
import { ExpoGoManifestHandlerMiddleware } from '../ExpoGoManifestHandlerMiddleware';
import { ManifestMiddlewareOptions } from '../ManifestMiddleware';
import { ServerHeaders, ServerRequest } from '../server.types';

jest.mock('../../../../api/user/user');
jest.mock('../../../../log');
jest.mock('../../../../api/getProject', () => ({
  getProjectAsync: jest.fn(() => ({
    scopeKey: 'scope-key',
  })),
}));
jest.mock('@expo/code-signing-certificates', () => ({
  ...(jest.requireActual(
    '@expo/code-signing-certificates'
  ) as typeof import('@expo/code-signing-certificates')),
  generateKeyPair: jest.fn(() =>
    (
      jest.requireActual(
        '@expo/code-signing-certificates'
      ) as typeof import('@expo/code-signing-certificates')
    ).convertKeyPairPEMToKeyPair({
      publicKeyPEM: mockExpoRootChain.publicKeyPEM,
      privateKeyPEM: mockExpoRootChain.privateKeyPEM,
    })
  ),
}));
jest.mock('../../../../api/getProjectDevelopmentCertificate', () => ({
  getProjectDevelopmentCertificateAsync: jest.fn(() => mockExpoRootChain.developmentCertificate),
}));
jest.mock('../../../../api/getExpoGoIntermediateCertificate', () => ({
  getExpoGoIntermediateCertificateAsync: jest.fn(
    () => mockExpoRootChain.expoGoIntermediateCertificate
  ),
}));
jest.mock('@expo/config-plugins', () => ({
  Updates: {
    getRuntimeVersion: jest.fn(() => '45.0.0'),
  },
}));
jest.mock('../../../../api/signManifest', () => ({
  signExpoGoManifestAsync: jest.fn((manifest) => JSON.stringify(manifest)),
}));
jest.mock('../resolveAssets', () => ({
  resolveManifestAssets: jest.fn(),
  resolveGoogleServicesFile: jest.fn(),
}));
jest.mock('../../../../api/settings', () => ({
  APISettings: {
    isOffline: false,
  },
}));
jest.mock('../resolveEntryPoint', () => ({
  resolveEntryPoint: jest.fn(() => './index.js'),
}));
jest.mock('@expo/config', () => ({
  getProjectConfigDescriptionWithPaths: jest.fn(),
  getConfig: jest.fn(() => ({
    pkg: {},
    exp: {
      sdkVersion: '45.0.0',
      name: 'my-app',
      slug: 'my-app',
    },
  })),
}));

const asReq = (req: Partial<ServerRequest>) => req as ServerRequest;

async function getMultipartPartAsync(
  partName: string,
  response: {
    body: string;
    headers: ServerHeaders;
  }
): Promise<MultipartPart | null> {
  const multipartParts = await parseMultipartMixedResponseAsync(
    response.headers.get('content-type') as string,
    Buffer.from(response.body)
  );
  const part = multipartParts.find((part) => isMultipartPartWithName(part, partName));
  return part ?? null;
}

beforeEach(() => {
  vol.reset();
});

describe('getParsedHeaders', () => {
  const middleware = new ExpoGoManifestHandlerMiddleware('/', {} as any);

  it('defaults to "none" with no platform header', () => {
    expect(
      middleware.getParsedHeaders(
        asReq({
          url: 'http://localhost:3000',
          headers: {},
        })
      )
    ).toEqual({
      acceptSignature: false,
      expectSignature: null,
      explicitlyPrefersMultipartMixed: false,
      hostname: null,
      platform: 'none',
    });
  });

  it('returns default values from headers', () => {
    expect(
      middleware.getParsedHeaders(
        asReq({ url: 'http://localhost:3000', headers: { 'expo-platform': 'android' } })
      )
    ).toEqual({
      explicitlyPrefersMultipartMixed: false,
      acceptSignature: false,
      expectSignature: null,
      hostname: null,
      platform: 'android',
    });
  });

  it(`returns a fully qualified object`, () => {
    expect(
      middleware.getParsedHeaders(
        asReq({
          url: 'http://localhost:3000',
          headers: {
            accept: 'multipart/mixed',
            host: 'localhost:8081',
            'expo-platform': 'ios',
            // This is different to the classic manifest middleware.
            'expo-accept-signature': 'true',
            'expo-expect-signature': 'wat',
          },
        })
      )
    ).toEqual({
      explicitlyPrefersMultipartMixed: true,
      acceptSignature: true,
      expectSignature: 'wat',
      hostname: 'localhost',
      // We don't care much about the platform here since it's already tested.
      platform: 'ios',
    });
  });
});

describe('_getManifestResponseAsync', () => {
  beforeEach(() => {
    APISettings.isOffline = false;
    asMock(getUserAsync).mockImplementation(async () => ({} as any));
  });

  function createMiddleware(
    extraExpFields?: Partial<ExpoConfig>,
    options: Partial<ManifestMiddlewareOptions> = {}
  ) {
    const middleware = new ExpoGoManifestHandlerMiddleware('/', options as any);

    middleware._resolveProjectSettingsAsync = jest.fn(
      async () =>
        ({
          expoGoConfig: {},
          hostUri: 'https://localhost:8081',
          bundleUrl: 'https://localhost:8081/bundle.js',
          exp: {
            slug: 'slug',
            extra: {
              eas: {
                projectId: 'projectId',
              },
            },
            ...extraExpFields,
          },
        } as any)
    );
    return middleware;
  }

  // Sanity
  it('returns an anon manifest', async () => {
    const middleware = createMiddleware();
    APISettings.isOffline = true;
    const results = await middleware._getManifestResponseAsync({
      explicitlyPrefersMultipartMixed: true,
      platform: 'android',
      acceptSignature: true,
      expectSignature: null,
      hostname: 'localhost',
    });
    expect(results.version).toBe('45.0.0');

    expect(results.headers).toEqual(
      new Map(
        Object.entries({
          'expo-protocol-version': 0,
          'expo-sfv-version': 0,
          'cache-control': 'private, max-age=0',
          'content-type': expect.stringContaining('multipart/mixed'),
        })
      )
    );

    const { body } = nullthrows(await getMultipartPartAsync('manifest', results));
    expect(JSON.parse(body)).toEqual({
      id: expect.any(String),
      createdAt: expect.any(String),
      runtimeVersion: '45.0.0',
      launchAsset: {
        key: 'bundle',
        contentType: 'application/javascript',
        url: 'https://localhost:8081/bundle.js',
      },
      assets: [],
      metadata: {},
      extra: {
        eas: {
          projectId: 'projectId',
        },
        expoClient: {
          extra: {
            eas: {
              projectId: 'projectId',
            },
          },
          hostUri: 'https://localhost:8081',
          slug: 'slug',
        },
        expoGo: {},
        scopeKey: expect.stringMatching(/@anonymous\/.*/),
      },
    });
  });

  it('returns a signed manifest', async () => {
    const middleware = createMiddleware();

    const results = await middleware._getManifestResponseAsync({
      explicitlyPrefersMultipartMixed: true,
      platform: 'android',
      acceptSignature: true,
      expectSignature: null,
      hostname: 'localhost',
    });
    expect(results.version).toBe('45.0.0');
    expect(results.headers.get('expo-manifest-signature')).toEqual(expect.any(String));

    const { body } = nullthrows(await getMultipartPartAsync('manifest', results));
    expect(JSON.parse(body)).toEqual({
      id: expect.any(String),
      createdAt: expect.any(String),
      runtimeVersion: '45.0.0',
      launchAsset: {
        key: 'bundle',
        contentType: 'application/javascript',
        url: 'https://localhost:8081/bundle.js',
      },
      assets: [],
      metadata: {},
      extra: {
        eas: {
          projectId: 'projectId',
        },
        expoClient: expect.anything(),
        expoGo: {},
        scopeKey: expect.not.stringMatching(/@anonymous\/.*/),
      },
    });
    expect(getProjectAsync).toBeCalledTimes(1);

    // Test memoization on API calls...
    await middleware._getManifestResponseAsync({
      explicitlyPrefersMultipartMixed: true,
      platform: 'android',
      acceptSignature: true,
      expectSignature: null,
      hostname: 'localhost',
    });

    expect(getProjectAsync).toBeCalledTimes(1);
  });

  it('returns a code signed manifest with developers own key when requested', async () => {
    vol.fromJSON({
      'certs/cert.pem': mockSelfSigned.certificate,
      'custom/private/key/path/private-key.pem': mockSelfSigned.privateKey,
    });

    const middleware = createMiddleware(
      {
        updates: {
          codeSigningCertificate: 'certs/cert.pem',
          codeSigningMetadata: {
            keyid: 'testkeyid',
            alg: 'rsa-v1_5-sha256',
          },
        },
      },
      {
        privateKeyPath: 'custom/private/key/path/private-key.pem',
      }
    );

    const results = await middleware._getManifestResponseAsync({
      explicitlyPrefersMultipartMixed: true,
      platform: 'android',
      acceptSignature: false,
      expectSignature: 'sig, keyid="testkeyid", alg="rsa-v1_5-sha256"',
      hostname: 'localhost',
    });
    expect(results.version).toBe('45.0.0');

    const { body, headers } = nullthrows(await getMultipartPartAsync('manifest', results));
    expect(headers.get('expo-signature')).toContain('keyid="testkeyid"');

    expect(JSON.parse(body)).toEqual({
      id: expect.any(String),
      createdAt: expect.any(String),
      runtimeVersion: '45.0.0',
      launchAsset: {
        key: 'bundle',
        contentType: 'application/javascript',
        url: 'https://localhost:8081/bundle.js',
      },
      assets: [],
      metadata: {},
      extra: {
        eas: {
          projectId: 'projectId',
        },
        expoClient: expect.anything(),
        expoGo: {},
        scopeKey: expect.not.stringMatching(/@anonymous\/.*/),
      },
    });

    const certificateChainMultipartPart = await getMultipartPartAsync('certificate_chain', results);
    expect(certificateChainMultipartPart).toBeNull();
  });

  it('returns a code signed manifest with expo-root chain when requested', async () => {
    const middleware = createMiddleware();

    const results = await middleware._getManifestResponseAsync({
      explicitlyPrefersMultipartMixed: true,
      platform: 'android',
      acceptSignature: false,
      expectSignature: 'sig, keyid="expo-root", alg="rsa-v1_5-sha256"',
      hostname: 'localhost',
    });
    expect(results.version).toBe('45.0.0');

    const { body: manifestPartBody, headers: manifestPartHeaders } = nullthrows(
      await getMultipartPartAsync('manifest', results)
    );
    expect(manifestPartHeaders.get('expo-signature')).toContain('keyid="expo-go"');

    expect(JSON.parse(manifestPartBody)).toEqual({
      id: expect.any(String),
      createdAt: expect.any(String),
      runtimeVersion: '45.0.0',
      launchAsset: {
        key: 'bundle',
        contentType: 'application/javascript',
        url: 'https://localhost:8081/bundle.js',
      },
      assets: [],
      metadata: {},
      extra: {
        eas: {
          projectId: 'projectId',
        },
        expoClient: expect.anything(),
        expoGo: {},
        scopeKey: expect.not.stringMatching(/@anonymous\/.*/),
      },
    });

    const { body: certificateChainPartBody } = nullthrows(
      await getMultipartPartAsync('certificate_chain', results)
    );
    expect(certificateChainPartBody).toMatchSnapshot();
  });

  it('returns text/plain when explicitlyPrefersMultipartMixed is false', async () => {
    const middleware = createMiddleware();
    APISettings.isOffline = true;
    const results = await middleware._getManifestResponseAsync({
      explicitlyPrefersMultipartMixed: false,
      platform: 'android',
      acceptSignature: true,
      expectSignature: null,
      hostname: 'localhost',
    });
    expect(results.version).toBe('45.0.0');

    expect(results.headers).toEqual(
      new Map(
        Object.entries({
          'expo-protocol-version': 0,
          'expo-sfv-version': 0,
          'cache-control': 'private, max-age=0',
          'content-type': 'text/plain',
        })
      )
    );
  });
});
